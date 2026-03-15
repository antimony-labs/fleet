use shared_types::NodeTelemetry;
use sysinfo::{CpuRefreshKind, RefreshKind, System};
use std::time::{SystemTime, UNIX_EPOCH};
use jsonwebtoken::{encode, EncodingKey, Header, Algorithm};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
struct Claims {
    sub: String,
    exp: usize,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let hostname = std::env::var("HOSTNAME").unwrap_or_else(|_| "unknown_node".to_string());
    // Load the private key injected by the vault
    let private_key_pem = std::env::var("FLEET_PRIVATE_KEY")
        .expect("FLEET_PRIVATE_KEY environment variable is required to authenticate with the Core API");
    let encoding_key = EncodingKey::from_ed_pem(private_key_pem.as_bytes())?;

    let client = reqwest::Client::new();
    let api_url = "https://api.antimony-labs.com/telemetry";

    println!("Starting Fleet Agent for node: {}", hostname);

    let mut sys = System::new_with_specifics(RefreshKind::new().with_cpu(CpuRefreshKind::everything()).with_memory(sysinfo::MemoryRefreshKind::everything()));
    
    // Wait for the first CPU tick to calculate usage accurately
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    loop {
        sys.refresh_cpu();
        sys.refresh_memory();

        let cpu_usage = sys.global_cpu_info().cpu_usage();
        let ram_used_mb = sys.used_memory() / 1024 / 1024;
        let ram_total_mb = sys.total_memory() / 1024 / 1024;
        
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();

        let payload = NodeTelemetry {
            hostname: hostname.clone(),
            cpu_usage,
            ram_used_mb,
            ram_total_mb,
            tailscale_ip: get_tailscale_ip(),
            timestamp_sec: now as i64,
        };

        // Generate short-lived JWT for this specific request
        let claims = Claims {
            sub: hostname.clone(),
            exp: (now + 60) as usize,
        };
        let token = encode(&Header::new(Algorithm::EdDSA), &claims, &encoding_key)?;

        // Ship the telemetry to the secure API
        let res = client.post(api_url)
            .header("Authorization", format!("Bearer {}", token))
            .json(&payload)
            .send()
            .await;

        match res {
            Ok(response) if response.status().is_success() => {
                println!("[{}] Telemetry pushed successfully.", now);
            }
            Ok(response) => {
                println!("[{}] API rejected telemetry: {}", now, response.status());
            }
            Err(e) => {
                println!("[{}] Network error pushing telemetry: {}", now, e);
            }
        }

        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
}

// Shells out to fetch the Tailscale IP if available
fn get_tailscale_ip() -> String {
    use std::process::Command;
    let output = Command::new("tailscale").arg("ip").arg("-4").output();
    
    if let Ok(out) = output 
        && out.status.success() 
        && let Ok(ip) = String::from_utf8(out.stdout) {
            return ip.trim().to_string();
    }
    
    "127.0.0.1".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{decode, DecodingKey, Validation};

    #[test]
    fn test_jwt_generation_and_payload_structure() {
        // 1. Generate a mock keypair for testing
        let private_key_pem = include_bytes!("../../../core/fleet_api/private_key.pem");
        let public_key_pem = include_bytes!("../../../core/fleet_api/public_key.pem");
        
        let encoding_key = EncodingKey::from_ed_pem(private_key_pem).unwrap();
        let decoding_key = DecodingKey::from_ed_pem(public_key_pem).unwrap();

        let hostname = "test_agent_node".to_string();
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();

        // 2. Generate the token the exact way the agent does
        let claims = Claims {
            sub: hostname.clone(),
            exp: (now + 60) as usize,
        };
        let token = encode(&Header::new(Algorithm::EdDSA), &claims, &encoding_key).unwrap();

        // 3. Verify it with the Core API's decoding key
        let mut validation = Validation::new(Algorithm::EdDSA);
        validation.set_required_spec_claims(&["exp", "sub"]);
        let token_data = decode::<Claims>(&token, &decoding_key, &validation).unwrap();

        assert_eq!(token_data.claims.sub, "test_agent_node");

        // 4. Verify Payload structure
        let payload = NodeTelemetry {
            hostname,
            cpu_usage: 12.5,
            ram_used_mb: 1024,
            ram_total_mb: 8192,
            tailscale_ip: "100.83.147.83".to_string(),
            timestamp_sec: now as i64,
        };

        assert_eq!(payload.cpu_usage, 12.5);
        assert_eq!(payload.tailscale_ip, "100.83.147.83");
    }
}
