#!/bin/bash

# manage_ports.sh
# Ein Skript zum Auflisten laufender Docker-Container, offener Ports,
# Identifizieren von Docker-verwalten Ports, Bestimmen von Anwendungen, die durch Proxys bedient werden,
# Anzeigen von Inbound- und Outbound-Status basierend auf ufw-Regeln,
# und Ermöglichen des Öffnens oder Schließens unerwünschter Ports mit ufw.

# Sicherstellen, dass das Skript mit Root-Rechten ausgeführt wird
if [ "$EUID" -ne 0 ]; then
  echo "Bitte führen Sie das Skript als root oder mit sudo aus."
  exit 1
fi

# Funktion zum Überprüfen, ob ein Befehl existiert
command_exists() {
  command -v "$1" &> /dev/null
}

# Überprüfen, ob ufw installiert ist
if ! command_exists ufw; then
  echo "ufw (Uncomplicated Firewall) ist nicht installiert."
  echo "Bitte installieren Sie ufw und versuchen Sie es erneut."
  exit 1
fi

# Überprüfen, ob Docker installiert ist
DOCKER_INSTALLED=false
if command_exists docker; then
  DOCKER_INSTALLED=true
else
  echo "Docker ist nicht installiert. Docker-Port-Erkennung wird übersprungen."
fi

# Überprüfen, ob Docker Compose installiert ist und die Version bestimmen
DOCKER_COMPOSE_INSTALLED=false
DOCKER_COMPOSE_VERSION=""
if command_exists docker-compose; then
  DOCKER_COMPOSE_INSTALLED=true
  DOCKER_COMPOSE_VERSION=$(docker-compose version --short 2>/dev/null)
elif command_exists docker && docker compose version &> /dev/null; then
  DOCKER_COMPOSE_INSTALLED=true
  DOCKER_COMPOSE_VERSION=$(docker compose version --short 2>/dev/null)
fi

if [ "$DOCKER_COMPOSE_INSTALLED" = true ]; then
  echo "Docker Compose erkannt: $DOCKER_COMPOSE_VERSION"
else
  echo "Docker Compose ist nicht installiert. Docker Compose-bezogene Funktionen werden übersprungen."
fi

# ufw aktivieren, wenn es nicht bereits aktiv ist
ufw status | grep -q "Status: inactive"
if [ $? -eq 0 ]; then
  echo "ufw ist nicht aktiv. ufw wird aktiviert..."
  ufw --force enable
fi

# Funktion zur Anzeige laufender Docker-Container
display_docker_ps() {
  echo ""
  echo "===== Laufende Docker-Container ====="

  if [ "$DOCKER_INSTALLED" = true ]; then
    # Überprüfen, ob Container laufen
    RUNNING_CONTAINERS=$(docker ps --format '{{.ID}} {{.Names}} {{.Image}} {{.Status}} {{.Ports}}')

    if [ -z "$RUNNING_CONTAINERS" ]; then
      echo "Keine laufenden Docker-Container."
    else
      # Header definieren
      printf "%-12s %-30s %-35s %-25s %-50s\n" "CONTAINER ID" "NAME" "IMAGE" "STATUS" "PORTS"
      echo "---------------------------------------------------------------------------------------------------------------------------------------------------------------------"

      # Informationen zu jedem laufenden Container anzeigen
      while read -r CONTAINER_ID NAME IMAGE STATUS PORTS; do
        # Umgang mit Ports, die Leerzeichen enthalten oder leer sind
        if [[ -z "$PORTS" ]]; then
          PORTS="N/A"
        fi
        printf "%-12s %-30s %-35s %-25s %-50s\n" "$CONTAINER_ID" "$NAME" "$IMAGE" "$STATUS" "$PORTS"
      done <<< "$RUNNING_CONTAINERS"
    fi
  else
    echo "Docker ist nicht installiert. Auflistung der Docker-Container wird übersprungen."
  fi

  echo "===================================="
  echo ""
}

# Funktion zur Ermittlung von Service-Namen und Beschreibung
get_service_info() {
  local port=$1
  local protocol=$2
  local service_name=""
  local description=""

  # Bekannte Ports mit besseren Beschreibungen definieren
  case "$port/$protocol" in
    22/tcp)
      service_name="SSH"
      description="Secure Shell für Remote-Login"
      ;;
    53/tcp|53/udp)
      service_name="DNS"
      description="Domain Name System zur Auflösung von Domainnamen"
      ;;
    80/tcp)
      service_name="HTTP"
      description="Hypertext Transfer Protocol für Webverkehr"
      ;;
    443/tcp)
      service_name="HTTPS"
      description="Sicheres HTTP für verschlüsselten Webverkehr"
      ;;
    3306/tcp)
      service_name="MySQL"
      description="MySQL-Datenbankserver"
      ;;
    123/udp)
      service_name="NTP"
      description="Network Time Protocol für Zeitsynchronisation"
      ;;
    6379/tcp)
      service_name="Redis"
      description="Redis In-Memory-Datenspeicher"
      ;;
    *)
      # Versuch, aus /etc/services zu lesen
      service_name=$(awk -v port="$port" -v proto="$protocol" -F '[ \t/]+' \
        '$2 == port && $3 == proto {print $1; exit}' /etc/services)
      if [ -n "$service_name" ]; then
        description="Standarddienst"
      else
        service_name="Unbekannt"
        description="Keine zusätzlichen Informationen verfügbar"
      fi
      ;;
  esac

  echo "$service_name|$description"
}

# Funktion zur Sammlung offener Ports von Docker-Diensten
collect_docker_ports() {
  # Liste der laufenden Docker-Container erhalten
  CONTAINERS=$(docker ps -q)

  for CONTAINER_ID in $CONTAINERS; do
    # Container-Name für Referenz erhalten
    CONTAINER_NAME=$(docker inspect -f '{{.Name}}' "$CONTAINER_ID" | sed 's/\///g')

    # Port-Mappings im Format PORT/PROTO erhalten (z.B. 80/tcp)
    PORT_MAPPINGS=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{range $conf}}{{printf "%s\n" $p}}{{end}}{{end}}{{end}}' "$CONTAINER_ID")

    while read -r PORT_PROTO; do
      # Sicherstellen, dass das Format gültig ist
      if [[ -n "$PORT_PROTO" && "$PORT_PROTO" =~ ^[0-9]+/(tcp|udp)$ ]]; then
        # Doppelte vermeiden und Port 0 ausschließen
        PORT_NUMBER=${PORT_PROTO%/*}
        if [ "$PORT_NUMBER" -ne 0 ]; then
          if [[ ! " ${DOCKER_PORTS[@]} " =~ " ${PORT_PROTO} " ]]; then
            DOCKER_PORTS+=("$PORT_PROTO")
            DOCKER_CONTAINER_PORTS["$PORT_PROTO"]="$CONTAINER_NAME"
          fi
        fi
      fi
    done <<< "$PORT_MAPPINGS"
  done
}

# Funktion zur Sammlung von Anwendungen, die durch Proxy-Container bedient werden
collect_proxied_apps() {
  # Assoziatives Array zur Speicherung der proxied Apps pro Proxy-Container
  declare -gA PROXIED_APPS

  # Proxy-Container anhand von Namensmustern identifizieren (z.B. "nginx-proxy")
  PROXY_CONTAINERS=$(docker ps --filter "name=nginx-proxy" --format '{{.Names}}')

  # Falls keine Proxy-Container anhand des Namens gefunden wurden, nach Image suchen
  if [[ -z "$PROXY_CONTAINERS" ]]; then
    PROXY_CONTAINERS=$(docker ps --filter "ancestor=nginxproxy/nginx-proxy" --format '{{.Names}}')
  fi

  # Über jeden Proxy-Container iterieren
  for PROXY_CONTAINER in $PROXY_CONTAINERS; do
    # Netzwerke ermitteln, mit denen der Proxy-Container verbunden ist
    PROXY_NETWORKS=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$PROXY_CONTAINER")

    # Alle Netzwerknamen extrahieren
    IFS=' ' read -r -a NETWORK_ARRAY <<< "$PROXY_NETWORKS"

    for PROXY_NETWORK in "${NETWORK_ARRAY[@]}"; do
      # Container finden, die mit dem gleichen Netzwerk verbunden sind und das Label VIRTUAL_HOST haben
      PROXIED_CONTAINERS=$(docker ps --filter "network=$PROXY_NETWORK" --filter "label=VIRTUAL_HOST" --format '{{.Names}}')

      # VIRTUAL_HOST-Werte von proxied Containern sammeln
      for APP_CONTAINER in $PROXIED_CONTAINERS; do
        VIRTUAL_HOST=$(docker inspect -f '{{index .Config.Labels "VIRTUAL_HOST"}}' "$APP_CONTAINER")
        if [[ -n "$VIRTUAL_HOST" ]]; then
          # VIRTUAL_HOST zum Proxy's proxied Apps hinzufügen
          if [[ -z "${PROXIED_APPS[$PROXY_CONTAINER]}" ]]; then
            PROXIED_APPS[$PROXY_CONTAINER]="$VIRTUAL_HOST"
          else
            PROXIED_APPS[$PROXY_CONTAINER]+=", $VIRTUAL_HOST"
          fi
        fi
      done
    done
  done
}

# Funktion zur Sammlung offener Ports von Docker Compose-Diensten
collect_docker_compose_ports() {
  # Bestimmen des korrekten Docker Compose-Befehls basierend auf der Version
  if command_exists docker-compose; then
    COMPOSE_CMD="docker-compose"
  elif command_exists docker && docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
  else
    echo "Docker Compose Befehl nicht gefunden. Docker Compose Port-Sammlung wird übersprungen."
    return
  fi

  # Liste der laufenden Docker Compose-Projekte erhalten
  if [[ "$COMPOSE_CMD" == "docker compose" ]]; then
    # Docker Compose V2
    COMPOSE_PROJECTS=$(docker compose ls --quiet 2>/dev/null)
  else
    # Docker Compose V1 unterstützt 'ls' nicht. Als Workaround alle eindeutigen Projekt-Namen von laufenden Containern auflisten
    COMPOSE_PROJECTS=$(docker ps --format '{{.Labels}}' | grep 'com.docker.compose.project=' | awk -F '=' '{print $2}' | sort -u)
  fi

  for PROJECT_ID in $COMPOSE_PROJECTS; do
    # Dienste im Projekt erhalten
    if [[ "$COMPOSE_CMD" == "docker compose" ]]; then
      SERVICES=$(docker compose -p "$PROJECT_ID" ps --services 2>/dev/null)
    else
      SERVICES=$(docker-compose -p "$PROJECT_ID" ps --services 2>/dev/null)
    fi

    for SERVICE in $SERVICES; do
      # Exponierte Ports für den Dienst erhalten
      if [[ "$COMPOSE_CMD" == "docker compose" ]]; then
        # Docker Compose V2
        PORT_MAPPINGS=$(docker compose -p "$PROJECT_ID" port "$SERVICE" 80 2>/dev/null)
      else
        # Docker Compose V1
        PORT_MAPPINGS=$(docker-compose -p "$PROJECT_ID" port "$SERVICE" 80 2>/dev/null)
      fi

      # HOST_PORT und PROTOCOL extrahieren
      if [[ -n "$PORT_MAPPINGS" ]]; then
        HOST_PORT=$(echo "$PORT_MAPPINGS" | awk -F':' '{print $2}')
        PROTOCOL=$(echo "$PORT_MAPPINGS" | awk '{print tolower($2)}')
        KEY="$HOST_PORT/$PROTOCOL"

        # Extrahierte Werte validieren
        if [[ "$HOST_PORT" =~ ^[0-9]+$ && "$PROTOCOL" =~ ^(tcp|udp)$ ]]; then
          # Doppelte vermeiden und Port 0 ausschließen
          PORT_NUMBER=${KEY%/*}
          if [ "$PORT_NUMBER" -ne 0 ]; then
            if [[ ! " ${DOCKER_PORTS[@]} " =~ " ${KEY} " ]]; then
              DOCKER_PORTS+=("$KEY")
              DOCKER_CONTAINER_PORTS["$KEY"]="$PROJECT_ID/$SERVICE"
            fi
          fi
        fi
      fi
    done
  done
}

# Funktion zur Sammlung offener Ports vom Host-System
collect_host_ports() {
  # ss verwenden, um lauschende Ports aufzulisten
  while read -r proto local_addr remote_addr state pid_program; do
    # Port extrahieren
    port=$(echo "$local_addr" | awk -F':' '{print $NF}')
    # Nur TCP und UDP berücksichtigen
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
      continue
    fi
    # Port 0 ausschließen
    if [ "$port" -eq 0 ]; then
      continue
    fi
    # Schlüssel bilden
    KEY="$port/$proto"
    # Doppelte vermeiden
    if [[ ! " ${HOST_PORTS[@]} " =~ " ${KEY} " ]]; then
      HOST_PORTS+=("$KEY")
    fi
  done < <(ss -tunl | tail -n +2 | awk '{print $1, $4, $5, $6, $7}')

  # Zusätzlich /proc/net/tcp und /proc/net/udp parsen für umfassendere Abdeckung
  for PROTOCOL in tcp udp; do
    while read -r line; do
      # Überschriftenzeile überspringen
      if [[ $line =~ ^sl ]]; then
        continue
      fi
      fields=($line)
      local_address=${fields[1]}
      state=${fields[3]}

      # Nur LISTEN-Zustand für TCP
      if [ "$PROTOCOL" == "tcp" ] && [ "$state" != "0A" ]; then
        continue
      fi

      # Port (Hex) extrahieren
      port_hex=${local_address#*:}
      port=$((16#$port_hex))

      # Port 0 ausschließen
      if [ "$port" -eq 0 ]; then
        continue
      fi

      # Schlüssel bilden
      KEY="$port/$PROTOCOL"

      # Doppelte vermeiden
      if [[ ! " ${HOST_PORTS[@]} " =~ " ${KEY} " ]]; then
        HOST_PORTS+=("$KEY")
      fi
    done < "/proc/net/${PROTOCOL}"
  done
}

# Funktion zum Parsen der ufw-Regeln und Extrahieren von erlaubten und verweigerten Ports
parse_ufw_rules() {
  # ufw-Status im ausführlichen Format erhalten
  ufw_status=$(ufw status verbose)

  # Standard eingehende und ausgehende Richtlinien extrahieren
  DEFAULT_IN=$(echo "$ufw_status" | grep "^Default: " | awk '{print $3}')
  DEFAULT_OUT=$(echo "$ufw_status" | grep "^Default: " | awk '{print $5}')

  # Zeilen mit DENY und ALLOW Aktionen für IN extrahieren
  denied_ports_in=$(echo "$ufw_status" | grep -E "DENY\s+IN" | awk '{print $1}' | grep "/tcp\|/udp")
  allowed_ports_in=$(echo "$ufw_status" | grep -E "ALLOW\s+IN" | awk '{print $1}' | grep "/tcp\|/udp")

  # Zeilen mit DENY und ALLOW Aktionen für OUT extrahieren
  denied_ports_out=$(echo "$ufw_status" | grep -E "DENY\s+OUT" | awk '{print $1}' | grep "/tcp\|/udp")
  allowed_ports_out=$(echo "$ufw_status" | grep -E "ALLOW\s+OUT" | awk '{print $1}' | grep "/tcp\|/udp")

  # In Arrays umwandeln
  IFS=$'\n' read -rd '' -a DENIED_PORTS_IN <<< "$denied_ports_in"
  IFS=$'\n' read -rd '' -a ALLOWED_PORTS_IN <<< "$allowed_ports_in"
  IFS=$'\n' read -rd '' -a DENIED_PORTS_OUT <<< "$denied_ports_out"
  IFS=$'\n' read -rd '' -a ALLOWED_PORTS_OUT <<< "$allowed_ports_out"
}

# Funktion zur Bestimmung des Status eines Ports für Inbound und Outbound
determine_port_status() {
  local port_proto="$1"
  local in_status=""
  local out_status=""

  # Inbound-Status bestimmen
  if [[ " ${DENIED_PORTS_IN[@]} " =~ " ${port_proto} " ]]; then
    in_status="Denied"
  elif [[ " ${ALLOWED_PORTS_IN[@]} " =~ " ${port_proto} " ]]; then
    in_status="Allowed"
  else
    # Standard eingehende Richtlinie verwenden
    if [[ "$DEFAULT_IN" == "deny" ]]; then
      in_status="Denied"
    else
      in_status="Allowed"
    fi
  fi

  # Outbound-Status bestimmen
  if [[ " ${DENIED_PORTS_OUT[@]} " =~ " ${port_proto} " ]]; then
    out_status="Denied"
  elif [[ " ${ALLOWED_PORTS_OUT[@]} " =~ " ${port_proto} " ]]; then
    out_status="Allowed"
  else
    # Standard ausgehende Richtlinie verwenden
    if [[ "$DEFAULT_OUT" == "deny" ]]; then
      out_status="Denied"
    else
      out_status="Allowed"
    fi
  fi

  echo "$in_status|$out_status"
}

# Initialisierung von Arrays
declare -a DOCKER_PORTS=()
declare -A DOCKER_CONTAINER_PORTS=()
declare -a HOST_PORTS=()
declare -a ALL_OPEN_PORTS=()
declare -a DENIED_PORTS_IN=()
declare -a ALLOWED_PORTS_IN=()
declare -a DENIED_PORTS_OUT=()
declare -a ALLOWED_PORTS_OUT=()
declare -gA PROXIED_APPS=()

# Docker-Ports sammeln, falls Docker installiert ist
if [ "$DOCKER_INSTALLED" = true ]; then
  collect_docker_ports
fi

# Docker Compose-Ports sammeln, falls Docker Compose installiert ist
if [ "$DOCKER_COMPOSE_INSTALLED" = true ]; then
  collect_docker_compose_ports
fi

# Host-Ports sammeln
collect_host_ports

# ufw-Regeln sammeln
parse_ufw_rules

# Proxied Apps sammeln
collect_proxied_apps

# Alle offenen Ports kombinieren
ALL_OPEN_PORTS=("${DOCKER_PORTS[@]}" "${HOST_PORTS[@]}")

# Duplikate entfernen
ALL_OPEN_PORTS=($(printf "%s\n" "${ALL_OPEN_PORTS[@]}" | sort -u))

# Laufende Docker-Container anzeigen
display_docker_ps

# Offene Ports dem Benutzer anzeigen mit Servicenamen, Protokollen, In- und Out-Status
echo ""
echo "Die folgenden Ports sind auf Ihrem Server geöffnet:"
echo ""
printf "%-6s %-6s %-30s %-10s %-10s %-150s\n" "Port" "Proto" "Service" "In" "Out" "Beschreibung"
echo "-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
for KEY in "${ALL_OPEN_PORTS[@]}"; do
  PORT=${KEY%/*}
  PROTOCOL=${KEY#*/}
  SERVICE_INFO=$(get_service_info "$PORT" "$PROTOCOL")
  SERVICE_NAME=${SERVICE_INFO%|*}
  DESCRIPTION=${SERVICE_INFO#*|}

  # Überprüfen, ob der Port einem Docker-Container zugeordnet ist
  if [[ " ${DOCKER_PORTS[@]} " =~ " ${KEY} " ]]; then
    CONTAINER_NAME=${DOCKER_CONTAINER_PORTS["$KEY"]}
    # Überprüfen, ob dieser Container ein Proxy ist und proxied Apps hat
    if [[ -n "${PROXIED_APPS[$CONTAINER_NAME]}" ]]; then
      SERVICE_DISPLAY="$SERVICE_NAME"
      DESCRIPTION="$DESCRIPTION (Docker: $CONTAINER_NAME, Proxied Apps: ${PROXIED_APPS[$CONTAINER_NAME]})"
    else
      SERVICE_DISPLAY="$SERVICE_NAME"
      DESCRIPTION="$DESCRIPTION (Docker: $CONTAINER_NAME)"
    fi
  else
    SERVICE_DISPLAY="$SERVICE_NAME"
  fi

  # Inbound- und Outbound-Status bestimmen
  PORT_STATUS=$(determine_port_status "$KEY")
  IN_STATUS=${PORT_STATUS%|*}
  OUT_STATUS=${PORT_STATUS#*|}

  # Status zur Beschreibung hinzufügen
  DESCRIPTION="$DESCRIPTION (In: $IN_STATUS, Out: $OUT_STATUS)"

  printf "%-6s %-6s %-30s %-10s %-10s %-150s\n" "$PORT" "$PROTOCOL" "$SERVICE_DISPLAY" "$IN_STATUS" "$OUT_STATUS" "$DESCRIPTION"
done

# Benutzeraufforderung zum Öffnen oder Schließen von Ports
for KEY in "${ALL_OPEN_PORTS[@]}"; do
  PORT=${KEY%/*}
  PROTOCOL=${KEY#*/}
  SERVICE_INFO=$(get_service_info "$PORT" "$PROTOCOL")
  SERVICE_NAME=${SERVICE_INFO%|*}
  DESCRIPTION=${SERVICE_INFO#*|}

  # Überprüfen, ob der Port einem Docker-Container zugeordnet ist
  if [[ " ${DOCKER_PORTS[@]} " =~ " ${KEY} " ]]; then
    CONTAINER_NAME=${DOCKER_CONTAINER_PORTS["$KEY"]}
    # Überprüfen, ob dieser Container ein Proxy ist und proxied Apps hat
    if [[ -n "${PROXIED_APPS[$CONTAINER_NAME]}" ]]; then
      DESCRIPTION="$DESCRIPTION (Docker: $CONTAINER_NAME, Proxied Apps: ${PROXIED_APPS[$CONTAINER_NAME]})"
    else
      DESCRIPTION="$DESCRIPTION (Docker: $CONTAINER_NAME)"
    fi
  fi

  # Inbound- und Outbound-Status bestimmen
  PORT_STATUS=$(determine_port_status "$KEY")
  IN_STATUS=${PORT_STATUS%|*}
  OUT_STATUS=${PORT_STATUS#*|}

  echo ""
  echo "Port $PORT/$PROTOCOL wird häufig für '$SERVICE_NAME' verwendet."
  echo "Beschreibung: $DESCRIPTION"

  # Optionen für Inbound Verkehr anbieten
  echo "Möchten Sie den eingehenden Verkehr für Port $PORT/$PROTOCOL ändern?"
  echo "1) Offen (allow)"
  echo "2) Geschlossen (deny)"
  echo "3) Keine Änderung"
  read -p "Bitte wählen Sie eine Option für Inbound Verkehr (1/2/3): " ANSWER_IN

  case "$ANSWER_IN" in
    1)
      echo "Erlauben des eingehenden Verkehrs für Port $PORT/$PROTOCOL..."
      ufw allow "$PORT/$PROTOCOL" >/dev/null 2>&1
      echo "Eingehender Verkehr für Port $PORT/$PROTOCOL wurde erlaubt."
      ;;
    2)
      if [ "$PORT" -eq 22 ] && [ "$PROTOCOL" == "tcp" ]; then
        echo "Warnung: Sie versuchen, den SSH-Port (22/tcp) zu schließen."
        read -p "Sind Sie sicher, dass Sie den SSH-Port 22/tcp blockieren möchten? Sie könnten den Remote-Zugang verlieren. (y/n): " SSH_CONFIRM
        if [[ ! "$SSH_CONFIRM" =~ ^[Yy]$ ]]; then
          echo "Schließen des eingehenden Verkehrs für Port 22/tcp wird übersprungen."
        else
          echo "Schließen des eingehenden Verkehrs für Port $PORT/$PROTOCOL..."
          ufw deny "$PORT/$PROTOCOL" >/dev/null 2>&1
          echo "Eingehender Verkehr für Port $PORT/$PROTOCOL wurde verweigert."
        fi
      else
        echo "Schließen des eingehenden Verkehrs für Port $PORT/$PROTOCOL..."
        ufw deny "$PORT/$PROTOCOL" >/dev/null 2>&1
        echo "Eingehender Verkehr für Port $PORT/$PROTOCOL wurde verweigert."
      fi
      ;;
    3)
      echo "Keine Änderung am eingehenden Verkehr für Port $PORT/$PROTOCOL."
      ;;
    *)
      echo "Ungültige Option. Keine Änderung am eingehenden Verkehr für Port $PORT/$PROTOCOL."
      ;;
  esac

  # Optionen für Outbound Verkehr anbieten
  echo ""
  echo "Möchten Sie den ausgehenden Verkehr für Port $PORT/$PROTOCOL ändern?"
  echo "1) Offen (allow)"
  echo "2) Geschlossen (deny)"
  echo "3) Keine Änderung"
  read -p "Bitte wählen Sie eine Option für Outbound Verkehr (1/2/3): " ANSWER_OUT

  case "$ANSWER_OUT" in
    1)
      echo "Erlauben des ausgehenden Verkehrs für Port $PORT/$PROTOCOL..."
      ufw allow out "$PORT/$PROTOCOL" >/dev/null 2>&1
      echo "Ausgehender Verkehr für Port $PORT/$PROTOCOL wurde erlaubt."
      ;;
    2)
      echo "Schließen des ausgehenden Verkehrs für Port $PORT/$PROTOCOL..."
      ufw deny out "$PORT/$PROTOCOL" >/dev/null 2>&1
      echo "Ausgehender Verkehr für Port $PORT/$PROTOCOL wurde verweigert."
      ;;
    3)
      echo "Keine Änderung am ausgehenden Verkehr für Port $PORT/$PROTOCOL."
      ;;
    *)
      echo "Ungültige Option. Keine Änderung am ausgehenden Verkehr für Port $PORT/$PROTOCOL."
      ;;
  esac
done

echo ""
echo "Firewall-Regeln aktualisiert. Aktueller ufw-Status:"
ufw status verbose
