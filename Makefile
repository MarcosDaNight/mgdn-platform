SHELL := /bin/bash
.DEFAULT_GOAL := help

TF      ?= terraform
TFDIR   := infra
ENV     := set -a && source ./.env && set +a &&
ENV_ABS := set -a && source ../.env && set +a &&
# Acesso pela tailnet (MagicDNS): mgdn-primary ou mgdn-secondary. Sem tailnet:
# HOST=<IP público> com ssh_break_glass = true no terraform.tfvars.
HOST    ?= mgdn-primary
SSH      = ssh -o StrictHostKeyChecking=accept-new ubuntu@$(HOST)
# O papel vem do hostname (mgdn-primary -> primary): o /etc/mgdn-platform/env é 0600.
COMPOSE := sudo docker compose -f /opt/mgdn-platform/deploy/$$(hostname | sed s/^mgdn-//)/compose.yaml
HS      := sudo docker exec $$(sudo docker ps -q --filter label=com.docker.compose.service=headscale) headscale

.PHONY: help
help: ## Lista os comandos
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# --- Infra ----------------------------------------------------------------------

.PHONY: bootstrap init plan apply destroy
bootstrap: ## Cria o bucket do state remoto (uma vez) e roda o init
	@$(ENV) scripts/bootstrap-state.sh
	@$(MAKE) --no-print-directory init

init: ## terraform init
	@cd $(TFDIR) && $(ENV_ABS) $(TF) init -input=false

plan: ## terraform plan
	@cd $(TFDIR) && $(ENV_ABS) $(TF) plan

apply: ## terraform apply
	@cd $(TFDIR) && $(ENV_ABS) $(TF) apply

destroy: ## Destroi tudo, inclusive o IP público (o roteador de casa precisaria ser reconfigurado)
	@cd $(TFDIR) && $(ENV_ABS) $(TF) destroy

# --- Tailnet --------------------------------------------------------------------

.PHONY: tailnet-nodes tailnet-register tailnet-key headscale-drain
tailnet-nodes: ## Lista os aparelhos da tailnet
	@$(SSH) '$(HS) nodes list'

tailnet-register: ## Aprova um aparelho que mostrou "headscale auth register --auth-id ..." (AUTH_ID=<id>)
	@test -n "$(AUTH_ID)" || { echo "uso: make tailnet-register AUTH_ID=<id mostrado no aparelho> [NAME=iphone]"; exit 1; }
	@$(SSH) '$(HS) auth register --auth-id $(AUTH_ID) --user platform'
	@test -z "$(NAME)" || $(SSH) 'id=$$($(HS) nodes list -o json | python3 -c "import json,sys;print(max(n[\"id\"] for n in json.load(sys.stdin)))"); $(HS) nodes rename -i $$id $(NAME)'

tailnet-key: ## Chave de uso único (30 min) para `tailscale up --authkey` em Linux
	@$(SSH) '$(HS) preauthkeys create --user $$($(HS) users list -n platform -o json | python3 -c "import json,sys;print(json.load(sys.stdin)[0][\"id\"])") --expiration 30m'

headscale-drain: ## Antes de recriar a VM principal: pausa o GitOps, backup novo e Headscale parado de forma limpa
	@$(SSH) 'sudo systemctl stop mgdn-gitops.timer && sudo systemctl start mgdn-backup.service && sudo journalctl -u mgdn-backup -n 1 -o cat --no-pager && $(COMPOSE) stop headscale'
	@echo "Headscale parado: os clientes reconectam assim que a VM nova subir. Agora: make apply"

# --- Operação -------------------------------------------------------------------

.PHONY: ssh tunnel grafana-password status allowlist sync logs querylog test backup backups
ssh: ## SSH na VM (HOST=mgdn-primary ou mgdn-secondary, pela tailnet)
	@$(SSH)

tunnel: ## Grafana :3000, Prometheus :9090, Blocky :4000 e Alertmanager :9093 em localhost
	@echo "Grafana    http://localhost:3000  (user admin; senha: make grafana-password)"
	@echo "Prometheus http://localhost:9090"
	@echo "Blocky API http://localhost:4000"
	@echo "Alertmanager http://localhost:9093"
	@$(SSH) -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 4000:127.0.0.1:4000 -L 9093:127.0.0.1:9093

grafana-password: ## Senha do admin do Grafana
	@$(SSH) sudo cut -d= -f2 /etc/mgdn-platform/grafana.env

status: ## Commit aplicado, containers, tailnet, timers, RAM e disco
	@$(SSH) 'echo "commit aplicado: $$(sudo cat /var/lib/mgdn-platform/applied | cut -c1-7)"; \
	  $(COMPOSE) ps --format "table {{.Service}}\t{{.Status}}"; echo; \
	  tailscale status 2>/dev/null | head -5; echo; \
	  systemctl list-timers "mgdn-*" --no-pager; echo; free -h; df -h /'

allowlist: ## IP de casa liberado (via DDNS) e últimas trocas
	@$(SSH) 'sudo nft list set inet mgdn_allowlist allowed | grep -E "elements|allowed"; \
	  sudo journalctl -u mgdn-allowlist --since "-7 days" -o short-iso | grep -E "IP de casa|AVISO" | tail -5'

sync: ## Força o GitOps sync agora
	@$(SSH) 'sudo systemctl start mgdn-gitops.service; sudo journalctl -u mgdn-gitops -n 20 --no-pager'

logs: ## Logs do Blocky (SERVICE=headscale etc.)
	@$(SSH) '$(COMPOSE) logs --tail 100 -f $(or $(SERVICE),blocky)'

querylog: ## Últimos domínios bloqueados (N=50)
	@$(SSH) 'sudo sh -c "cat /var/lib/docker/volumes/mgdn_blocky-logs/_data/*.log" | awk -F"\t" "\$$5 ~ /BLOCKED/ {print \$$1, \$$2, \$$6}" | tail -n $(or $(N),50)'

backup: ## Faz um backup do Headscale agora
	@$(SSH) 'sudo systemctl start mgdn-backup.service; sudo journalctl -u mgdn-backup -n 3 -o cat --no-pager'

backups: ## Lista os backups mais recentes no bucket imutável (N=10)
	@$(SSH) 'sudo bash -c ". /etc/mgdn-platform/env; . /opt/mgdn-platform/scripts/s3.sh; s3_list headscale/ | tail -n $(or $(N),10)"'

test: ## Testa resolução e bloqueio nas duas VMs (IPs públicos, de casa) e pela tailnet
	@cd $(TFDIR) && $(ENV_ABS) p=$$($(TF) output -raw primary_ip) && s2=$$($(TF) output -raw secondary_ip 2>/dev/null); \
	 for s in $$p $$s2 100.64.0.1; do \
	   echo -n "$$s: resolve cloudflare.com -> "; dig +short +time=3 +tries=1 @$$s cloudflare.com | head -1; \
	   echo -n "$$s: bloqueia pagead2.googlesyndication.com -> "; dig +short +time=3 +tries=1 @$$s pagead2.googlesyndication.com | head -1; \
	 done

# --- Qualidade ------------------------------------------------------------------

.PHONY: hooks fmt lint test-infra
hooks: ## Instala os hooks do pre-commit neste clone
	@pre-commit install

fmt: ## Formata o Terraform
	@$(TF) fmt -recursive $(TFDIR)

lint: ## pre-commit em todos os arquivos + terraform validate
	@pre-commit run --all-files
	@cd $(TFDIR) && $(TF) validate -no-color >/dev/null && echo "terraform validate ok"

test-infra: ## terraform test (provider simulado, sem credenciais nem recursos)
	@cd $(TFDIR) && $(TF) test
