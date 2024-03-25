#!/bin/bash

# Quickly spin up a Synapse + Postgres in podman for testing.
# Copyright (C) 2024  Twilight Sparkle
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

scriptPath="$(readlink -f "$0")"
workDir="$(dirname "$scriptPath")"
configFile="$workDir/config.env"

function help {
    cat <<EOT
Usage: $scriptPath <option>

Options:
    admin:       Create Synapse admin account (username: admin. password: admin).
    delete:      Delete the environment, Synapse/Postgres data, and config files.
    gendock:     Regenerate the Docker Compose file.
    genele:      Regenerate the Element Web config file.
    genhook:     Regenerate the Hookshot config files.
    gensyn:      Regenerate the Synapse config and log config files.
    help:        This help text.
    restartall:  Restart all containers.
    restartele:  Restart the Element Web container.
    restarthook: Restart the Hookshot container.
    restartsyn:  Restart the Synapse container.
    setup:       Create, edit, (re)start the environment.
    stop:        Stop the environment without deleting it.

Note: restartall and setup will recreate all containers and remove orphaned
containers. Synapse/Postgres data is not deleted.
EOT
}

# Load config
if [[ ! -f "$configFile" ]]; then
    echo "Unable to load config file $configFile"
    exit 1
fi
source "$configFile"

# This variable needs to be exported so it can be used with yq
export synapsePortEnv="$synapsePort"

# Vars
synapseData="$workDir/synapse"
dockerComposeFile="$workDir/docker-compose.yaml"
elementConfigFile="$workDir/elementConfig.json"
hookshotConfigFile="$workDir/hookshotConfig.yaml"
hookshotInstallationScript="$workDir/installHookshot.sh"
hookshotRegistrationFile="$workDir/hookshotRegistration.yaml"
logConfigFile="$synapseData/localhost:$synapsePort.log.config"
postgresData="$workDir/postgres"
serverName="localhost:$synapsePort"
synapseConfigFile="$synapseData/homeserver.yaml"

# Check that required programs are installed on the system
function checkRequiredPrograms {
    programs=(bash podman podman-compose yq)
    missing=""
    for program in "${programs[@]}"; do
        if ! hash "$program" &>/dev/null; then
            missing+="\n- $program"
        fi
    done
    if [[ -n "$missing" ]]; then
        echo -e "Required programs are missing on this system. Please install:$missing"
        exit 1
    fi
}

# Check for required directories
function checkRequiredDirectories {
    [[ ! -d "$synapseData" ]] && mkdir "$synapseData"
}

# Create Synapse admin account
function createAdminAccount {
    podman exec \
        synapse-podman-synapse-1 \
        /bin/bash \
        -c "register_new_matrix_user \
            --admin \
            --config /data/homeserver.yaml \
            --password admin \
            --user admin"
    exit 0
}

# Delete the environment
function deleteEnvironment {
    msg="Enter YES to confirm deleting the environment and the directories/files postgres, synapse, docker-compose.yaml, and elementConfig.json: "
    read -rp "$msg" verification
    [[ "$verification" != "YES" ]] && exit 0
    podman-compose down --remove-orphans
   [[ -d "$hookshotConfigFile" ]] && rm -rf "$hookshotConfigFile"
   [[ -d "$hookshotInstallationScript" ]] && rm -rf "$hookshotInstallationScript"
   [[ -d "$hookshotRegistrationFile" ]] && rm -rf "$hookshotRegistrationFile"
   [[ -d "$postgresData" ]] && rm -rf "$postgresData"
   [[ -d "$synapseData" ]] && rm -rf "$synapseData"
   [[ -f "$dockerComposeFile" ]] && rm -rf "$dockerComposeFile"
   [[ -f "$elementConfigFile" ]] && rm -rf "$elementConfigFile"
}

# Create the podman-compose file or ask to overwrite
function generateDockerCompose {
   [[ "$enableDevelopHookshot" == true ]] && synapseAdditionalVolumes+=("$hookshotRegistrationFile:/hookshot.yml")
    synapseAdditionalVolumesYaml=""
    for volume in "${synapseAdditionalVolumes[@]}"; do
        synapseAdditionalVolumesYaml+="
      - $volume"
    done

    [[ -f "$dockerComposeFile" ]] && read -rp "Overwrite $dockerComposeFile? [y/N]: " verification
   [[ "$verification" == "y" ]] || [[ ! -f "$dockerComposeFile" ]] && cat <<EOT > "$dockerComposeFile"
# This file is managed by $scriptPath
version: "3"
services:
  synapse:
    image: $synapseImage
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      - SYNAPSE_CONFIG_PATH=/data/homeserver.yaml
    ports:
      - 127.0.0.1:8008-8009:8008-8009/tcp
      - 127.0.0.1:$synapsePort:$synapsePort/tcp
    volumes:
      - $synapseData:/data$synapseAdditionalVolumesYaml

  postgres:
    image: docker.io/postgres:16
    restart: unless-stopped
    environment:
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
      - POSTGRES_PASSWORD=password
      - POSTGRES_USER=synapse
    ports:
      - 127.0.0.1:$portgresPort:5432/tcp
    volumes:
      - $postgresData:/var/lib/postgresql/data
EOT

   [[ "$enableAdminer" == true ]] && [[ "$verification" == "y" ]] && cat <<EOT >> "$dockerComposeFile"

  adminer:
    image: docker.io/adminer:latest
    restart: unless-stopped
    environment:
      - ADMINER_DEFAULT_SERVER=postgres
    ports:
      - 127.0.0.1:$adminerPort:8080/tcp
EOT

   [[ "$enableElementWeb" == true ]] && [[ "$verification" == "y" ]] && cat <<EOT >> "$dockerComposeFile"

  elementweb:
    image: $elementImage
    restart: unless-stopped
    ports:
      - 127.0.0.1:$elementPort:80/tcp
    volumes:
      - $elementConfigFile:/app/config.json:ro
EOT

   [[ "$enableDevelopHookshot" == true ]] && [[ "$verification" == "y" ]] && cat <<EOT >> "$dockerComposeFile"

  hookshotdev:
    image: ubuntu
    restart: unless-stopped
    ports:
      - 127.0.0.1:8000:8000/tcp
      - 127.0.0.1:9000-9002:9000-9002/tcp
      - 127.0.0.1:9993:9993/tcp
    volumes:
      - $fullPathToClonedHookshotRepo:/hookshot
      - $hookshotConfigFile:/hookshot/config.json:ro
      - $hookshotRegistrationFile:/hookshot/registration.yaml:ro
      - $hookshotInstallationScript:/tmp/installHookshot.sh:ro
    entrypoint: sh -c "/tmp/installHookshot.sh"
EOT
}

# Generate Element Web config if not present or ask to overwrite
function generateElementConfig {
   [[ "$enableElementWeb" == true ]] && [[ -f "$elementConfigFile" ]] && read -rp "Overwrite $elementConfigFile? [y/N]: " verification
   [[ "$enableElementWeb" == true ]] && [[ "$verification" == "y" ]] || [[ ! -f "$elementConfigFile" ]] && cat <<EOT > "$elementConfigFile"
{
    "synapse-docker_notice": "This file is managed by $scriptPath",
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "dangerously_allow_unsafe_and_insecure_passwords": true,
    "default_country_code": "US",
    "default_federate": true,
    "default_server_config": {
        "m.homeserver": {
            "base_url": "http://$serverName",
            "server_name": "$serverName"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "default_theme": "dark",
    "disable_3pid_login": false,
    "disable_custom_urls": false,
    "disable_guests": false,
    "disable_login_language_selector": false,
    "element_call": {
        "brand": "Element Call",
        "participant_limit": 8,
        "url": "https://call.element.io"
    },
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api",
        "https://scalar-staging.riot.im/scalar/api"
    ],
    "jitsi": {
        "preferred_domain": "meet.element.io"
    },
    "map_style_url": "https://api.maptiler.com/maps/streets/style.json?key=fU3vlMsMn4Jb6dnEIFsx",
    "roomDirectory": {
        "servers": [
            "$serverName"
        ]
    },
    "setting_defaults": {
        "FTUE.userOnboardingButton": false,
        "MessageComposerInput.ctrlEnterToSend": true,
        "UIFeature.Feedback": false,
        "UIFeature.advancedSettings": true,
        "UIFeature.shareSocial": false,
        "alwaysShowTimestamps": true,
        "automaticErrorReporting": false,
        "ctrlFForSearch": true,
        "developerMode": true,
        "dontSendTypingNotifications": true,
        "sendReadReceipts": false,
        "sendTypingNotifications": false,
        "showChatEffects": false
    },
    "show_labs_settings": true
}
EOT
}

# Generate Hookshot config if not present or ask to overwrite
function generateHookshotConfig {
   [[ "$enableDevelopHookshot" == true ]] && [[ -f "$hookshotConfigFile" ]] && read -rp "Overwrite $hookshotConfigFile? [y/N]: " verification
   [[ "$enableDevelopHookshot" == true ]] && [[ "$verification" == "y" ]] || [[ ! -f "$hookshotConfigFile" ]] && cat <<EOT > "$hookshotConfigFile"
{
bridge:
  # Basic homeserver configuration
  domain: localhost:8448
  url: http://synapse-podman-synapse-1:8448
  mediaUrl: http://synapse-podman-synapse-1:8448
  port: 9993
  bindAddress: 0.0.0.0
passFile: passkey.pem
logging:
  # Logging settings. You can have a severity debug,info,warn,error
  level: debug
  colorize: true
  json: false
  timestampFormat: HH:mm:ss:SSS
listeners:
  - port: 9000
    bindAddress: 0.0.0.0
    resources:
      - webhooks
  - port: 9001
    bindAddress: 127.0.0.1
    resources:
      - metrics
      - provisioning
  - port: 9002
    bindAddress: 0.0.0.0
    resources:
      - widgets

feeds:
  enabled: true
  pollConcurrency: 4
  pollIntervalSeconds: 600
  pollTimeoutSeconds: 30

permissions:
  # Allow all users to send commands to existing services
  - actor: "*"
    services:
      - service: "*"
        level: admin

widgets:
  addToAdminRooms: false
  roomSetupWidget:
    addOnInvite: false
  disallowedIpRanges: []
  publicUrl: http://localhost:9002/widgetapi/v1/static
  branding:
    widgetTitle: Hookshot Configuration
  openIdOverrides:
    localhost:8448: "http://synapse-podman-synapse-1:8448"
EOT

   [[ "$enableDevelopHookshot" == true ]] && [[ -f "$hookshotRegistrationFile" ]] && read -rp "Overwrite $hookshotRegistrationFile? [y/N]: " verification
   [[ "$enableDevelopHookshot" == true ]] && [[ "$verification" == "y" ]] || [[ ! -f "$hookshotRegistrationFile" ]] && cat <<EOT > "$hookshotRegistrationFile"
id: matrix-hookshot # This can be anything, but must be unique within your homeserver
as_token: 9iO25vz2YWYE # This again can be a random string
hs_token: 157Xvm6RAJIE # ..as can this
namespaces:
  rooms: []
  users: # In the following, foobar is your homeserver's domain
    - regex: "@hookshot:localhost:8448" # Matches the localpart of all serviceBots in config.yml
      exclusive: true

sender_localpart: hookshot
url: "http://hookshotdev:9993" # This should match the bridge.port in your config file
rate_limited: false
EOT

   [[ "$enableDevelopHookshot" == true ]] && [[ -f "$hookshotInstallationScript" ]] && read -rp "Overwrite $hookshotInstallationScript? [y/N]: " verification
   [[ "$enableDevelopHookshot" == true ]] && [[ "$verification" == "y" ]] || [[ ! -f "$hookshotInstallationScript" ]] && cat <<EOT > "$hookshotInstallationScript"
#!/bin/bash

if [[ -f "/hookshotIsInstalled" ]] && exit 0

apt update
apt -y upgrade
apt install -y curl dnsutils gcc inetutils-ping libssl-dev pkg-config python3 vim

# https://github.com/nvm-sh/nvm#installing-and-updating
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source /root/.bashrc

nvm install --lts
nvm use --lts

# https://classic.yarnpkg.com/lang/en/docs/install/#mac-stable
npm install --global yarn

# https://rustup.rs/
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

cd /hookshot/
openssl genpkey -out passkey.pem -outform PEM -algorithm RSA -pkeyopt rsa_keygen_bits:4096

cargo install mdbook
yarn # build everything

touch /hookshotIsInstalled
EOT

   [[ -f "$hookshotInstallationScript" ]] && chmod +x "$hookshotInstallationScript"
}

# Generate Synapse config if not present or ask to overwrite
function generateSynapseConfig {
    [[ -f "$synapseConfigFile" ]] || [[ -f "$logConfigFile" ]] && \
        read -rp "Overwrite $synapseConfigFile and $logConfigFile? [y/N]: " verification
    if [[ "$verification" == "y" ]] || [[ ! -f "$synapseConfigFile" ]]; then
       [[ -f "$synapseConfigFile" ]] && rm "$synapseConfigFile"
       [[ -f "$logConfigFile" ]] && rm "$logConfigFile"

        podman run \
            --entrypoint "/bin/bash" \
            --interactive \
            --rm \
            --tty \
            --volume "$synapseData":/data \
            "$synapseImage" \
            -c "python3 -m synapse.app.homeserver \
                --config-path /data/homeserver.yaml \
                --data-directory /data \
                --generate-config \
                --report-stats no \
                --server-name $serverName"

        # Customize Synapse config
        yq -i '.handlers.file.filename = "/data/homeserver.log"' "$logConfigFile"
        yq -i 'del(.listeners[0].bind_addresses)' "$synapseConfigFile"
        yq -i '
            .listeners[0].bind_addresses[0] = "0.0.0.0" |
            .listeners[0].port = env(synapsePortEnv) |
            .database.name = "psycopg2" |
            .database.args.user = "synapse" |
            .database.args.password = "password" |
            .database.args.database = "synapse" |
            .database.args.host = "postgres" |
            .database.args.cp_min = 5 |
            .database.args.cp_max = 10 |
            .trusted_key_servers[0].accept_keys_insecurely = true |
            .suppress_key_server_warning = true |
            .enable_registration = true |
            .enable_registration_without_verification = true |
            .presence.enabled = false
        ' "$synapseConfigFile"
       [[ "$enableDevelopHookshot" == true ]] && yq -i '.app_service_config_files += "/hookshot.yaml"' "$synapseConfigFile"
    fi
}

# Create/Start/Restart comtainers
function restartAll {
    podman-compose up --detach --force-recreate --remove-orphans
}

# Restart the Element Web container
function restartElement {
    podman restart synapse-podman-elementweb-1
}

# Restart the Hookshot container
function restartHookshot {
    podman restart synapse-podman-hookshotdev-1
}

# Restart the Synapse container
function restartSynapse {
    podman restart synapse-podman-synapse-1
}

# Stop the environment
function stopEnvironment {
    podman-compose stop
}

checkRequiredPrograms
checkRequiredDirectories

case $1 in
    admin)      createAdminAccount      ;;
    delete)     deleteEnvironment       ;;
    gendock)    generateDockerCompose   ;;
    genele)     generateElementConfig   ;;
    genhook)    generateHookshotConfig   ;;
    gensyn)     generateSynapseConfig   ;;
    restartall) restartAll              ;;
    restartele) restartElement          ;;
    restarthook)restartHookshot          ;;
    restartsyn) restartSynapse          ;;
    setup)
        generateSynapseConfig
        generateDockerCompose
        generateElementConfig
        generateHookshotConfig
        restartAll
        ;;
    stop)       stopEnvironment         ;;
    *)          help                    ;;
esac
