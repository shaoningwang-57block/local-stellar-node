# stellar-tool (local-stellar-node)

A lightweight CLI to manage a local Stellar/Soroban node toolkit (non-Docker).  
It provides one-command start/stop/reset, health checks, log viewing, and a `test` wrapper for running Rust tests (with optional coverage).

## Repo Layout

This CLI expects the following structure:

local-stellar-node/

bin/stellar-tool

script/start-service.sh

script/stop-service.sh

script/reset-node.sh

log/stellar-core.log   (optional)

log/stellar-rpc.log    (optional)

log/caddy.log          (optional)


## Install

```shell
curl -fsSL https://raw.githubusercontent.com/shaoningwang-57block/local-stellar-node/main/install/install.sh | bash
```

## Development
- Stellar CLI
## Usage
### Node Control

```bash
stellar-tool start
stellar-tool stop
stellar-tool reset
````

### **Health / Status**

```
stellar-tool status
stellar-tool health
stellar-tool wait [timeout_seconds=60] [interval_seconds=1]
```

### **Logs**

```
stellar-tool logs rpc [lines=200]
stellar-tool logs core [lines=200]
stellar-tool logs caddy [lines=200]
```

## **Test Runner**

stellar-tool test is a wrapper around cargo test (and cargo llvm-cov for coverage).
### **Basic**

```
stellar-tool test
stellar-tool test -- --nocapture
```
### **Run tests in a specific project**

```
stellar-tool test --path ~/projects/your-rust-project -- --nocapture
```

### **Wait for the node before running tests**

```
stellar-tool test --wait
```

### **Coverage (requires** 

### **cargo-llvm-cov**

```
stellar-tool test --cov
stellar-tool test --cov-html
```

Install:

```
cargo install cargo-llvm-cov
```

### **Resource Usage Output**

  

Enable your test framework to print a resource usage table by exporting:

- STELLAR_TOOL_SHOW_USAGE=1 (enabled)
    
- STELLAR_TOOL_SHOW_USAGE=0 (disabled)
    

  

CLI flags:

```
stellar-tool test --usage
stellar-tool test --no-usage
```

> When --usage is enabled, the CLI automatically appends --nocapture

> so output will not be swallowed by Rust test harness.

  

## **Environment Variables**

- LOCAL_STELLAR_NODE_HOME
    
    Override toolkit root directory.
    
- STELLAR_RPC_URL
    
    Default RPC URL (default: http://127.0.0.1:9003).
    
- STELLAR_TOOL_TEST_DIR
    
    Default Rust project directory for stellar-tool test.
    
- STELLAR_TOOL_SHOW_USAGE
    
    Control resource usage output in tests (1 / 0).
    
## **License**

MIT (or your preferred license).

```
If you want, I can also add a tiny “Quick Start” section (download → chmod +x → run) in the same short style.
```