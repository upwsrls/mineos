# ===========================================================================
# mineOS - Makefile
# ---------------------------------------------------------------------------
# Semplifica build, packaging, installazione locale e test.
# Esegui `make help` per l'elenco dei comandi.
# ===========================================================================

# --- Variabili configurabili (override: `make iso UBUNTU_VERSION=24.04.3`) ---
PROJECT_NAME     := mineos
UBUNTU_VERSION   ?= 24.04.3
UBUNTU_ISO_NAME  ?= ubuntu-$(UBUNTU_VERSION)-live-server-amd64.iso

# --- Percorsi -------------------------------------------------------------
BUILD_DIR        := build
WORK_DIR         := $(BUILD_DIR)/work
DIST_DIR         := dist
AUTOINSTALL_DIR  := $(BUILD_DIR)/autoinstall

PAYLOAD          := $(DIST_DIR)/$(PROJECT_NAME)-payload.tar.gz
OUT_ISO          := $(BUILD_DIR)/$(PROJECT_NAME)-$(UBUNTU_VERSION)-autoinstall-amd64.iso
UBUNTU_ISO_PATH  := $(WORK_DIR)/$(UBUNTU_ISO_NAME)

# Destinazione per l'installazione locale (utile per test/staging).
DESTDIR          ?=
MINEOS_PREFIX    := /opt/mineos

# Esclusioni dal payload: cartelle di runtime che non vanno nell'immagine.
PAYLOAD_EXCLUDES := --exclude='opt/mineos/state/*' \
                    --exclude='opt/mineos/logs/*' \
                    --exclude='opt/mineos/miners/*' \
                    --exclude='opt/mineos/backups/*'

# Colori per output leggibile.
CYAN  := \033[36m
BOLD  := \033[1m
RESET := \033[0m

.DEFAULT_GOAL := help
.PHONY: help payload iso rebuild clean clean-all install-local update-check check-tools

# ---------------------------------------------------------------------------
help: ## Mostra questo aiuto
	@printf "$(BOLD)mineOS - comandi disponibili$(RESET)\n\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  $(CYAN)%-16s$(RESET) %s\n", $$1, $$2}'
	@printf "\nVariabili: UBUNTU_VERSION=$(UBUNTU_VERSION)  DESTDIR=$(DESTDIR)\n"

# ---------------------------------------------------------------------------
check-tools: ## Verifica i tool richiesti per la build (xorriso, wget, tar)
	@for t in xorriso wget tar; do \
		command -v $$t >/dev/null 2>&1 \
			&& printf "  ok   %s\n" "$$t" \
			|| printf "  MANCA %s (installa: sudo apt-get install -y xorriso wget)\n" "$$t"; \
	done

# ---------------------------------------------------------------------------
payload: ## Crea il tar.gz di mineOS da iniettare nell'ISO
	@mkdir -p $(DIST_DIR)
	@printf "$(BOLD)Creo il payload...$(RESET)\n"
	tar -czf $(PAYLOAD) -C $(CURDIR) $(PAYLOAD_EXCLUDES) opt etc
	@printf "Payload pronto: $(CYAN)$(PAYLOAD)$(RESET)\n"

# ---------------------------------------------------------------------------
iso: ## Builda l'ISO completa (scarica l'ISO Ubuntu se assente)
	@if [ -f "$(UBUNTU_ISO_PATH)" ]; then \
		printf "ISO Ubuntu trovata: $(UBUNTU_ISO_PATH)\n"; \
	else \
		printf "$(BOLD)ISO Ubuntu assente: verra' scaricata da build-iso.sh$(RESET)\n"; \
	fi
	cd $(BUILD_DIR) && ./build-iso.sh
	@printf "ISO generata: $(CYAN)$(OUT_ISO)$(RESET)\n"

# ---------------------------------------------------------------------------
rebuild: ## Ricostruisce l'ISO da zero (clean temporanei + payload + iso)
	@printf "$(BOLD)Rebuild completo dell'ISO...$(RESET)\n"
	$(MAKE) clean
	$(MAKE) payload
	$(MAKE) iso

# ---------------------------------------------------------------------------
clean: ## Pulisce file temporanei (work/, dist/, payload)
	@printf "$(BOLD)Pulizia file temporanei...$(RESET)\n"
	rm -rf $(WORK_DIR) $(DIST_DIR)
	@printf "Fatto. (ISO finale e ISO Ubuntu scaricata NON rimosse: usa 'make clean-all')\n"

# ---------------------------------------------------------------------------
clean-all: clean ## Pulizia totale, inclusi ISO generata e ISO Ubuntu scaricata
	rm -f $(OUT_ISO)
	@printf "Rimossa anche l'ISO generata.\n"

# ---------------------------------------------------------------------------
install-local: ## Installa mineOS sul sistema corrente (richiede root; usa DESTDIR per staging)
	@if [ -z "$(DESTDIR)" ] && [ "$$(id -u)" -ne 0 ]; then \
		printf "Errore: esegui con sudo (o specifica DESTDIR per staging).\n"; exit 1; \
	fi
	@printf "$(BOLD)Installo mineOS in $(DESTDIR)$(MINEOS_PREFIX)...$(RESET)\n"
	install -d $(DESTDIR)$(MINEOS_PREFIX) $(DESTDIR)/etc/systemd/system
	cp -a opt/mineos/. $(DESTDIR)$(MINEOS_PREFIX)/
	cp -a etc/systemd/system/. $(DESTDIR)/etc/systemd/system/
	chmod +x $(DESTDIR)$(MINEOS_PREFIX)/bin/*.sh $(DESTDIR)$(MINEOS_PREFIX)/bin/lib/*.sh
	install -d -m 700 $(DESTDIR)$(MINEOS_PREFIX)/config
	@# Abilita i servizi solo per un'installazione reale (DESTDIR vuoto).
	@if [ -z "$(DESTDIR)" ]; then \
		systemctl daemon-reload; \
		systemctl enable mineos-firstboot.service mineos-agent.service mineos-watchdog.service; \
		systemctl enable mineos-profit-switch.timer; \
		printf "Servizi abilitati. Riavvia per lanciare il first boot.\n"; \
	else \
		printf "Staging in $(DESTDIR): servizi NON abilitati.\n"; \
	fi

# ---------------------------------------------------------------------------
update-check: ## Simula un aggiornamento (DRY_RUN, nessuna modifica reale)
	@printf "$(BOLD)Simulazione aggiornamento (DRY_RUN=1)...$(RESET)\n"
	sudo env DRY_RUN=1 MINEOS_ROOT=$(CURDIR)/opt/mineos \
		$(CURDIR)/opt/mineos/bin/update-mineos.sh --force
