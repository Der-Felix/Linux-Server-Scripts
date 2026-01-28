#!/bin/bash

# ==============================================================================
# OpenSSL CA Manager - Professional Edition
# Description: Interaktives Management für eigene CAs und Zertifikate
# Standards: RSA 4096, SHA256, SAN Support, PFX & PEM Export
# ==============================================================================

# Farben für bessere Lesbarkeit
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Basis-Verzeichnis (aktueller Ordner)
BASE_DIR=$(pwd)/my_pki
ROOT_CA_DIR="$BASE_DIR/root_ca"
CERTS_DIR="$BASE_DIR/issued_certs"
CONFIG_DIR="$BASE_DIR/configs"

# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNUNG]${NC} $1"; }
log_error() { echo -e "${RED}[FEHLER]${NC} $1"; }

check_dependencies() {
    if ! command -v openssl &> /dev/null; then
        log_error "OpenSSL ist nicht installiert. Bitte installiere es (apt install openssl / yum install openssl)."
        exit 1
    fi
}

create_structure() {
    if [ ! -d "$BASE_DIR" ]; then
        log_info "Erstelle Verzeichnisstruktur unter $BASE_DIR..."
        mkdir -p "$ROOT_CA_DIR"
        mkdir -p "$CERTS_DIR"
        mkdir -p "$CONFIG_DIR"
        
        # Erstelle README für das Root Verzeichnis
        cat > "$BASE_DIR/README.txt" <<EOF
=== OpenSSL CA Manager Struktur ===

1. root_ca/
   Hier liegt das "Herz" deiner Zertifizierungsstelle.
   - rootCA.key: Der private Schlüssel der CA. NIEMALS weitergeben!
   - rootCA.crt: Das öffentliche Zertifikat. Dies muss auf allen Client-PCs/Servern importiert werden.
   - rootCA.srl: Serial-Number Tracking Datei.

2. issued_certs/
   Hier landen alle erstellten Zertifikate für Webseiten/Server.
   Jede Domain bekommt einen eigenen Unterordner.

3. configs/
   Temporäre Konfigurationsdateien für OpenSSL.
EOF
        log_success "Struktur erstellt."
    fi
}

# ------------------------------------------------------------------------------
# Core Funktionen
# ------------------------------------------------------------------------------

init_ca() {
    echo -e "\n${CYAN}=== Initialisierung der Root CA ===${NC}"
    
    if [ -f "$ROOT_CA_DIR/rootCA.key" ]; then
        log_warn "Eine Root CA existiert bereits in $ROOT_CA_DIR."
        read -p "Möchtest du sie wirklich überschreiben? Alle alten Zertifikate werden ungültig! (j/n): " confirm
        if [[ "$confirm" != "j" ]]; then
            return
        fi
    fi

    echo "Bitte gib die Daten für die Zertifizierungsstelle (CA) ein."
    read -p "Land (2 Buchstaben, z.B. DE): " COUNTRY
    read -p "Bundesland (z.B. Berlin): " STATE
    read -p "Stadt (z.B. Berlin): " CITY
    read -p "Organisation (z.B. Meine Firma Internal): " ORG
    read -p "Common Name für CA (z.B. 'MeineFirma Root CA'): " CN
    read -p "Gültigkeit in Tagen (Standard: 3650 für 10 Jahre): " DAYS
    DAYS=${DAYS:-3650}

    log_info "Generiere RSA 4096 Private Key für Root CA..."
    
    # Root Key generieren (AES256 verschlüsselt empfohlen, hier für Automation ohne Passphrase, 
    # aber in Produktion sollte man -aes256 hinzufügen)
    openssl genrsa -out "$ROOT_CA_DIR/rootCA.key" 4096

    log_info "Generiere Root Zertifikat..."
    openssl req -x509 -new -nodes -key "$ROOT_CA_DIR/rootCA.key" \
        -sha256 -days "$DAYS" -out "$ROOT_CA_DIR/rootCA.crt" \
        -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/CN=$CN"

    chmod 400 "$ROOT_CA_DIR/rootCA.key" # Read-only für Besitzer

    # Erstelle eine Erklärung für den Nutzer
    cat > "$ROOT_CA_DIR/WICHTIG_LESEN.txt" <<EOF
Dies ist der Ordner deiner Root CA.

DATEIEN:
- rootCA.key: Der Private Key. Dieser signiert alles. Wenn dieser gestohlen wird, ist alles unsicher.
- rootCA.crt: Das Zertifikat.

INSTALLATION:
Damit Browser (Chrome/Edge) keine Fehler anzeigen, muss 'rootCA.crt' importiert werden:
1. Windows: Doppelklick -> Zertifikat installieren -> Lokaler Computer -> "Vertrauenswürdige Stammzertifizierungsstellen".
2. Linux: cp rootCA.crt /usr/local/share/ca-certificates/ && update-ca-certificates
3. Firefox: Einstellungen -> Datenschutz -> Zertifikate -> Importieren -> Haken bei "Websites vertrauen".
EOF

    log_success "Root CA erfolgreich erstellt!"
    echo -e "Pfad: $ROOT_CA_DIR/rootCA.crt"
}

create_certificate() {
    echo -e "\n${CYAN}=== Neues Server/Client Zertifikat erstellen ===${NC}"

    if [ ! -f "$ROOT_CA_DIR/rootCA.key" ]; then
        log_error "Keine Root CA gefunden! Bitte zuerst Option 1 wählen."
        return
    fi

    read -p "Domain Name (z.B. myserver.lan oder *.intern.de): " DOMAIN
    # Dateisystem-sicherer Name
    DIR_NAME=$(echo "$DOMAIN" | tr -d '*.' | sed 's/^/wildcard_/' | sed 's/^wildcard_wildcard_/wildcard_/') 
    if [[ "$DOMAIN" != \** ]]; then
        DIR_NAME=$DOMAIN
    fi
    
    TARGET_DIR="$CERTS_DIR/$DIR_NAME"
    mkdir -p "$TARGET_DIR"

    read -p "IP-Adresse (Optional, Enter zum Überspringen): " IP_ADDR
    read -p "Gültigkeit in Tagen (z.B. 365 oder 825): " DAYS
    DAYS=${DAYS:-365}

    # Config File für diesen Request erstellen (Wichtig für SANs!)
    CONFIG_FILE="$CONFIG_DIR/${DIR_NAME}.cnf"
    
    cat > "$CONFIG_FILE" <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
C = DE
ST = Internal
L = Internal
O = Internal Security
CN = $DOMAIN

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
EOF

    # Wenn es ein Wildcard ist, fügen wir oft die Root Domain hinzu, aber * reicht meist.
    # Logik für IP Adressen hinzufügen
    if [ ! -z "$IP_ADDR" ]; then
        echo "IP.1 = $IP_ADDR" >> "$CONFIG_FILE"
    fi

    # 1. Private Key für Server
    log_info "Generiere Private Key für $DOMAIN..."
    openssl genrsa -out "$TARGET_DIR/privkey.pem" 4096

    # 2. CSR (Certificate Signing Request)
    log_info "Generiere CSR..."
    openssl req -new -key "$TARGET_DIR/privkey.pem" -out "$TARGET_DIR/server.csr" -config "$CONFIG_FILE"

    # 3. Signieren durch Root CA
    log_info "Signiere Zertifikat mit Root CA..."
    
    # Erstelle Erweiterungsdatei für das Signing (damit SANs übernommen werden)
    EXT_FILE="$CONFIG_DIR/${DIR_NAME}.ext"
    cat > "$EXT_FILE" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
EOF
    if [ ! -z "$IP_ADDR" ]; then
        echo "IP.1 = $IP_ADDR" >> "$EXT_FILE"
    fi

    openssl x509 -req -in "$TARGET_DIR/server.csr" \
        -CA "$ROOT_CA_DIR/rootCA.crt" -CAkey "$ROOT_CA_DIR/rootCA.key" \
        -CAcreateserial -out "$TARGET_DIR/cert.pem" \
        -days "$DAYS" -sha256 -extfile "$EXT_FILE"

    # 4. Exports erstellen
    log_info "Erstelle Export-Formate..."

    # Nginx / Apache (Fullchain = Cert + CA)
    cat "$TARGET_DIR/cert.pem" "$ROOT_CA_DIR/rootCA.crt" > "$TARGET_DIR/fullchain.pem"
    
    # Windows PFX
    echo -e "${YELLOW}Bitte setze ein Passwort für den Windows PFX Export (Enter für kein PW):${NC}"
    openssl pkcs12 -export -out "$TARGET_DIR/windows_iis.pfx" \
        -inkey "$TARGET_DIR/privkey.pem" \
        -in "$TARGET_DIR/cert.pem" \
        -certfile "$ROOT_CA_DIR/rootCA.crt"

    # Readme für diesen Export
    cat > "$TARGET_DIR/README_USAGE.txt" <<EOF
Zertifikate für: $DOMAIN

1. NGINX / APACHE (Linux Webserver):
   - ssl_certificate:     $TARGET_DIR/fullchain.pem
   - ssl_certificate_key: $TARGET_DIR/privkey.pem

2. WINDOWS (IIS / Exchange):
   - Benutze die Datei: windows_iis.pfx
   - Importiere sie in den Zertifikatsspeicher (Persönlich oder Webhosting).

3. DATEIEN:
   - cert.pem: Das reine Serverzertifikat.
   - fullchain.pem: Zertifikat + Root CA (Wichtig für vollständige Chain).
   - privkey.pem: Dein geheimer Schlüssel.
EOF

    log_success "Zertifikat erstellt in: $TARGET_DIR"
}

renew_cert() {
    echo -e "\n${CYAN}=== Zertifikat erneuern / neu ausstellen ===${NC}"
    echo "Dies ist im Grunde das gleiche wie das Erstellen eines neuen Zertifikats,"
    echo "aber wir nutzen die existierende Root CA, um die Laufzeit zu verlängern."
    echo "HINWEIS: Es wird ein neues Schlüsselpaar generiert (Best Practice)."
    create_certificate
}

show_menu() {
    clear
    echo -e "${GREEN}################################################"
    echo -e "#         LINUX PRO CA MANAGER v1.0            #"
    echo -e "################################################${NC}"
    echo -e "Arbeitsverzeichnis: $BASE_DIR\n"
    echo "1. Neue Root CA initialisieren (Start hier)"
    echo "2. Neues Zertifikat erstellen (Domain/Wildcard/IP)"
    echo "3. Zertifikat verlängern / neu ausstellen"
    echo "4. Struktur anzeigen"
    echo "5. Beenden"
    echo ""
    read -p "Auswahl [1-5]: " CHOICE

    case $CHOICE in
        1) init_ca ;;
        2) create_certificate ;;
        3) renew_cert ;;
        4) ls -R "$BASE_DIR"; read -p "Drücke Enter..." ;;
        5) exit 0 ;;
        *) echo "Ungültige Auswahl";;
    esac
}

# ------------------------------------------------------------------------------
# Main Logic
# ------------------------------------------------------------------------------

check_dependencies
create_structure

while true; do
    show_menu
    echo ""
    read -p "Drücke Enter um fortzufahren..."
done
