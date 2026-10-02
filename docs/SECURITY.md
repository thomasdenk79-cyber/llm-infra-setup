# Security

Only the LiteLLM gateway should be exposed to trusted clients. Do not expose SGLang directly to the Internet. Store API keys, Hugging Face tokens and SSH keys outside the repository. Review published ports, bind addresses and firewall rules before deployment. Run rootless services as a dedicated user where practical.
