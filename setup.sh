#!/bin/bash
set -e

# --- FUNCTIE OM EEN SPECIFIEKE SERVICE TE RESETTEN ---
reset_service() {
    local service_name=$1
    local paths_to_delete=()
    local docker_service=$service_name

    # Map service namen naar de bijbehorende mappen
    case "$service_name" in
        "database")
            paths_to_delete=("./database/data/" "./database/chroma/")
            # Meerdere containers hangen van de database af, dus we resetten ook chromadb
            docker_service="database chromadb"
            ;;
        "n8n")
            paths_to_delete=("./automation/n8n/")
            ;;
        "mqtt")
            paths_to_delete=("./automation/mqtt/")
            ;;
        "nextcloud")
            paths_to_delete=("./apps/nextcloud/" "$HOME/appdock/nextcloud")
            ;;
        "obsidian")
            paths_to_delete=("./apps/obsidian/")
            ;;
        "web")
            paths_to_delete=("./apps/web/")
            ;;
        "homeassistant")
            paths_to_delete=("./automation/homeassistant/")
            ;;
        *)
            echo "❌ Fout: Onbekende service '$service_name'."
            echo "Beschikbare services: database, n8n, mqtt, nextcloud, obsidian, web, homeassistant"
            exit 1
            ;;
    esac

    echo "--- 🔄 Service Reset Modus ---"
    echo "De volgende Docker container(s) worden gestopt en verwijderd: $docker_service"
    echo "De volgende mappen worden permanent verwijderd:"
    for path in "${paths_to_delete[@]}"; do
        echo " - $path"
    done
    echo ""

    read -p "Weet je dit zeker? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "-> Stoppen en verwijderen van Docker container(s)..."
        docker compose rm -s -f $docker_service

        echo "-> Mappen verwijderen..."
        for path in "${paths_to_delete[@]}"; do
            if [ -d "$path" ]; then
                sudo rm -rf "$path"
                echo "--> '$path' verwijderd."
            fi
        done
        echo "--- ✅ Reset voor '$service_name' voltooid! ---"
    else
        echo "Reset geannuleerd."
    fi
}

# --- FUNCTIE OM HET HELE PROJECT TE RESETTEN ---
reset_full_project() {
    echo "--- 🔄 Volledige Project Reset Modus ---"
    echo "De volgende mappen worden permanent verwijderd:"
    echo " - ./apps/"
    echo " - ./automation/"
    echo " - ./database/"
    echo ""
    read -p "Weet je dit zeker? Dit kan niet ongedaan worden gemaakt. (y/n) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "-> Stoppen en verwijderen van alle Docker containers en volumes..."
        docker compose down -v

        echo "-> Mappen verwijderen..."
        if [ -d "./apps" ]; then sudo rm -rf ./apps; echo "--> ./apps verwijderd."; fi
        if [ -d "./automation" ]; then sudo rm -rf ./automation; echo "--> ./automation verwijderd."; fi
        if [ -d "./database" ]; then sudo rm -rf ./database; echo "--> ./database verwijderd."; fi
        echo ""
        echo "--- ✅ Volledige reset voltooid! ---"
    else
        echo "Reset geannuleerd."
    fi
}

# --- HOOFDLOGICA VAN HET SCRIPT ---
if [ "$1" == "-r" ]; then
    if [ -z "$2" ]; then
        # Als alleen "-r" wordt gegeven, voer een volledige reset uit
        reset_full_project
    else
        # Als "-r <servicenaam>" wordt gegeven, voer een gerichte reset uit
        reset_service "$2"
    fi
    exit 0
fi


echo "--- Plongo Setup Script ---"
echo "[1/4] Benodigde mappen aanmaken..."
mkdir -p ./database
mkdir -p ./automation/n8n/config
mkdir -p ./automation/mqtt/config
mkdir -p ./automation/mqtt/data
mkdir -p ./automation/mqtt/log
# --- Mappen voor de apps ---
mkdir -p ./apps/web/src
mkdir -p ./apps/web/public/html
mkdir -p ./apps/nextcloud/html
mkdir -p ./apps/obsidian/notes
mkdir -p ./apps/obsidian/templates 
mkdir -p ./automation/homeassistant
mkdir -p $HOME/appdock/nextcloud/html
# touch ./automation/homeassistant/configuration.yaml
# touch ./automation/homeassistant/automations.yaml
# touch ./automation/homeassistant/scripts.yaml
# touch ./automation/homeassistant/scenes.yaml

# --- STAP 2 IS NU VOOR ALLE CONFIGS ---
echo "[2/4] Configuratiebestanden aanmaken..."

# --- Maak het MQTT wachtwoordbestand aan ---
echo "-> MQTT wachtwoordbestand aanmaken..."
touch ./automation/mqtt/config/pwdfile
if [ -f ./.env ]; then
    export $(grep -v '^#' .env | xargs)
    if [ -n "$MQTT_USER" ] && [ -n "$MQTT_PASSWORD" ]; then
        echo "--> Gebruiker '$MQTT_USER' toevoegen aan MQTT..."
        # Gebruik een tijdelijke docker container om het 'mosquitto_passwd' commando uit te voeren
        # Dit is de officiële manier en zorgt voor de juiste encryptie.
        docker run --rm -v ./automation/mqtt/config:/mosquitto/config eclipse-mosquitto \
        mosquitto_passwd -b /mosquitto/config/pwdfile "$MQTT_USER" "$MQTT_PASSWORD"
        echo "--> Gebruiker succesvol toegevoegd."
    else
        echo "--> LET OP: MQTT_USER of MQTT_PASSWORD niet ingesteld in .env. Wachtwoordbestand blijft leeg."
    fi
else
    echo "--> LET OP: .env bestand niet gevonden. Wachtwoordbestand blijft leeg."
    echo "--> Zorg ervoor dat er een .env bestand is zoals de example.env. Vul alle vereiste variabelen in."
    exit 1
fi

# --- Maak database initialisatiescript aan ---
if [ ! -f ./database/init-databases.sh ]; then
    cat > ./database/init-databases.sh << 'EOF'
    #!/bin/bash
    set -e # Stop het script onmiddellijk als een commando faalt
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- === Database voor Core-Geheugen ===
    CREATE USER ${CORE_USER_NAME} WITH PASSWORD '${CORE_USER_PASSWORD}';
    CREATE DATABASE ${CORE_MEMORY_DB_NAME};
    GRANT ALL PRIVILEGES ON DATABASE ${CORE_MEMORY_DB_NAME} TO ${CORE_USER_NAME};
    ALTER DATABASE ${CORE_MEMORY_DB_NAME} OWNER TO ${CORE_USER_NAME};
    -- === Gebruiker & Database voor n8n ===
    CREATE USER ${N8N_DB_USER} WITH PASSWORD '${N8N_DB_PASSWORD}';
    CREATE DATABASE ${N8N_DB_NAME};
    GRANT ALL PRIVILEGES ON DATABASE ${N8N_DB_NAME} TO ${N8N_DB_USER};
    ALTER DATABASE ${N8N_DB_NAME} OWNER TO ${N8N_DB_USER};
    -- === Gebruiker & Database voor Nextcloud ===
    CREATE USER ${NEXTCLOUD_DB_USER} WITH PASSWORD '${NEXTCLOUD_DB_PASSWORD}';
    CREATE DATABASE ${NEXTCLOUD_DB_NAME};
    GRANT ALL PRIVILEGES ON DATABASE ${NEXTCLOUD_DB_NAME} TO ${NEXTCLOUD_DB_USER};
    ALTER DATABASE ${NEXTCLOUD_DB_NAME} OWNER TO ${NEXTCLOUD_DB_USER};
    -- === Gebruiker & Database voor AI Agents ===
    CREATE USER ${AI_AGENTS_DB_USER} WITH PASSWORD '${AI_AGENTS_DB_PASSWORD}';
    CREATE DATABASE ${AI_AGENTS_DB_NAME};
    GRANT ALL PRIVILEGES ON DATABASE ${AI_AGENTS_DB_NAME} TO ${AI_AGENTS_DB_USER};
    ALTER DATABASE ${AI_AGENTS_DB_NAME} OWNER TO ${AI_AGENTS_DB_USER};
EOSQL
EOF
    echo "-> ./database/init-databases.sh aangemaakt."
else
    echo "-> ./database/init-databases.sh bestand al aanwezig."
fi
chmod +x ./database/init-databases.sh

# --- Maak mosquitto.conf aan ---
cat > ./automation/mqtt/config/mosquitto.conf << 'EOF'
allow_anonymous false
password_file /mosquitto/config/pwdfile
listener 1883
listener 9001
protocol websockets
persistence true
persistence_file mosquitto.db
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
EOF
echo "-> ./automation/mqtt/config/mosquitto.conf aangemaakt."

# --- Genereer de bestanden voor de Web App ---
cat > ./apps/web/Dockerfile << 'EOF'
FROM php:8.2-apache
RUN apt-get update && apt-get install -y \
    libpq-dev \
    && docker-php-ext-install pdo pdo_pgsql
COPY ./src /usr/src/default-site
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2-foreground"]
EOF
echo "-> ./apps/web/Dockerfile aangemaakt."
cat > ./apps/web/docker-entrypoint.sh << 'EOF'
#!/bin/bash
set -e
TARGET_DIR="/var/www/html"
if [ -z "$(ls -A $TARGET_DIR)" ]; then
    echo "-> Web directory is leeg. Kopiëren van de standaard Plongo-site..."
    cp -r /usr/src/default-site/* $TARGET_DIR
fi
exec "$@"
EOF
chmod +x ./apps/web/docker-entrypoint.sh
echo "-> ./apps/web/docker-entrypoint.sh aangemaakt en uitvoerbaar gemaakt."
cat > ./apps/web/src/index.php << 'EOF'
<!DOCTYPE html>
<html lang="nl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Website is Live!</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;700&display=swap" rel="stylesheet">
    <style> body { font-family: 'Inter', sans-serif; } </style>
</head>
<body class="bg-gray-900 text-white flex items-center justify-center min-h-screen">
    <div class="text-center p-8 bg-gray-800 rounded-xl shadow-2xl max-w-lg mx-auto border border-gray-700">
        <svg class="mx-auto h-16 w-16 text-blue-400 mb-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01" />
        </svg>
        <h1 class="text-4xl font-bold text-white mb-2">Web Active</h1>
        <p class="text-gray-400 mb-6">Apache server is aan a neef</p>
        <div class="bg-gray-700 rounded-lg p-4 text-left">
            <p class="text-sm text-gray-300">Contact: <code class="bg-gray-600 text-blue-300 px-2 py-1 rounded-md text-xs"><a href="https://instagram.com/plongo.nl" target="_blank"> @plongo.nl</a></code>.</p>
            <p class="text-sm text-gray-300 mt-2">PHP Versie: <span class="font-mono text-green-400"><?php echo phpversion(); ?></span></p>
        </div>
    </div>
</body>
</html>
EOF
echo "-> ./apps/web/src/index.php aangemaakt."

# --- NIEUW: Genereer de bestanden voor de Obsidian App ---

# 1. Maak de Dockerfile voor Obsidian aan
cat > ./apps/obsidian/Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates ./templates
EXPOSE 5000
CMD ["flask", "run", "--host=0.0.0.0"]
EOF
echo "-> ./apps/obsidian/Dockerfile aangemaakt."

# 2. Maak het requirements.txt bestand aan
cat > ./apps/obsidian/requirements.txt << 'EOF'
Flask==3.0.0
EOF
echo "-> ./apps/obsidian/requirements.txt aangemaakt."

# 3. Maak de Python/Flask app.py aan
cat > ./apps/obsidian/app.py << 'EOF'
import os
import re
from pathlib import Path
from functools import wraps
from flask import Flask, request, jsonify, render_template 

app = Flask(__name__)

NOTES_DIR = Path('/notes')
API_KEY = os.environ.get('OBSIDIAN_API_KEY')

def require_api_key(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not API_KEY:
            return jsonify({"error": "Configuration Error", "message": "API Key is not configured on the server."}), 500
        auth_header = request.headers.get('Authorization')
        if not auth_header:
            return jsonify({"error": "Unauthorized", "message": "Authorization header is missing."}), 401
        try:
            auth_type, provided_key = auth_header.split()
            if auth_type.lower() != 'bearer':
                return jsonify({"error": "Unauthorized", "message": "Authorization type must be 'Bearer'."}), 401
        except ValueError:
            return jsonify({"error": "Unauthorized", "message": "Invalid Authorization header format."}), 401
        
        if provided_key != API_KEY:
            return jsonify({"error": "Forbidden", "message": "Invalid API Key."}), 403
        return f(*args, **kwargs)
    return decorated_function

@app.errorhandler(404)
def not_found_error(error):
    return jsonify({"error": "Not Found", "message": "The requested URL was not found on the server."}), 404

@app.errorhandler(405)
def method_not_allowed_error(error):
    return jsonify({"error": "Method Not Allowed", "message": "The method is not allowed for the requested URL."}), 405

@app.errorhandler(Exception)
def internal_server_error(error):
    return jsonify({"error": "Internal Server Error", "message": "An unexpected error occurred on the server."}), 500

def secure_path(note_path: str) -> Path | None:
    if not note_path:
        return None
    safe_relative_path = note_path.lstrip('/')
    full_path = NOTES_DIR.joinpath(safe_relative_path).resolve()
    if NOTES_DIR.resolve() in full_path.parents or NOTES_DIR.resolve() == full_path:
        return full_path
    return None

def build_file_tree(dir_path: Path) -> list:
    tree = []
    notes_subdir_base = NOTES_DIR.joinpath('notes')
    for item in sorted(list(dir_path.iterdir())):
        if item.name.startswith('.'):
            continue
        relative_path = item.relative_to(notes_subdir_base)
        if item.is_dir():
            tree.append({
                "name": item.name, "type": "directory", "path": str(relative_path),
                "children": build_file_tree(item)
            })
        elif item.name.endswith('.md'):
            tree.append({"name": item.name, "type": "file", "path": str(relative_path)})
    return tree

@app.route("/")
def index():
    return render_template('index.html')

@app.route("/notes", methods=['GET', 'POST'])
@require_api_key
def handle_notes_collection():
    if request.method == 'GET':
        notes_subdir = NOTES_DIR.joinpath('notes')
        if not notes_subdir.is_dir(): return jsonify([])
        return jsonify(build_file_tree(notes_subdir))
    
    if request.method == 'POST':
        data = request.json
        if not data or 'title' not in data or 'content' not in data:
            return jsonify({"error": "Bad Request", "message": "Request body must contain 'title' and 'content' keys."}), 400
        
        title = data['title']
        safe_title = re.sub(r'[^a-zA-Z0-9\s_-]', '', title).strip()
        if not safe_title:
            return jsonify({"error": "Bad Request", "message": "Title is invalid or contains only special characters."}), 400
        
        note_path = f"notes/{safe_title}.md"
        safe_note_path = secure_path(note_path)

        if not safe_note_path:
            return jsonify({"error": "Bad Request", "message": "Generated path is invalid."}), 400
        
        if safe_note_path.exists():
            return jsonify({"error": "Conflict", "message": f"A note with the title '{title}' already exists."}), 409

        try:
            safe_note_path.parent.mkdir(parents=True, exist_ok=True)
            safe_note_path.write_text(data['content'], encoding='utf-8')
            return jsonify({"success": True, "message": f"Note '{safe_title}.md' created."}), 201
        except Exception as e:
            raise e

@app.route("/notes/<path:note_path>", methods=['GET', 'PUT', 'DELETE'])
@require_api_key 
def handle_single_note(note_path):
    full_item_path = os.path.join('notes', note_path)
    safe_path = secure_path(full_item_path)

    if not safe_path or not safe_path.exists() or safe_path.name.startswith('.'):
        return jsonify({"error": "Not Found", "message": f"The path '{note_path}' does not exist."}), 404

    if request.method == 'GET':
        if safe_path.is_dir():
            return jsonify(build_file_tree(safe_path))
        if safe_path.is_file():
            content = safe_path.read_text(encoding='utf-8')
            return jsonify({"path": note_path, "content": content})

    if request.method == 'PUT':
        data = request.json
        if not data or 'content' not in data:
            return jsonify({"error": "Bad Request", "message": "Request body must contain a 'content' key."}), 400
        
        try:
            safe_path.write_text(data['content'], encoding='utf-8')
            return jsonify({"success": True, "message": f"Note '{note_path}' updated."})
        except Exception as e:
            raise e
            
    if request.method == 'DELETE':
        try:
            if safe_path.is_file():
                safe_path.unlink()
                return jsonify({"success": True, "message": f"Note '{note_path}' deleted."})
            else:
                return jsonify({"error": "Bad Request", "message": "Path is a directory, not a file."}), 400
        except Exception as e:
            raise e
EOF
echo "-> ./apps/obsidian/app.py aangemaakt."

# 4. Maak de HTML template voor Obsidian aan
cat > ./apps/obsidian/templates/index.html << 'EOF'
<!DOCTYPE html>
<html lang="nl" class="h-full bg-gray-900">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Obsidian Web Notes</title>

    <meta name="description" content="Een webinterface voor het beheren van notities in een Obsidian kluis.">
    <meta name="author" content="Plongo">

    <meta name="theme-color" content="#111827"> <link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>📝</text></svg>">
    <link rel="apple-touch-icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>📝</text></svg>">

    <meta property="og:title" content="Obsidian Web Notes">
    <meta property="og:description" content="Een webinterface voor het beheren van notities.">
    <meta property="og:type" content="website">

    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="h-full text-gray-200 antialiased">
    <div class="relative min-h-screen md:flex">
        <div id="sidebar-overlay" class="fixed inset-0 bg-black bg-opacity-50 z-20 hidden md:hidden"></div>
        
        <aside id="sidebar" class="fixed inset-y-0 left-0 z-30 w-full max-w-xs transform -translate-x-full transition-transform duration-300 ease-in-out bg-gray-800 p-4 border-r border-gray-700 flex flex-col md:relative md:w-1/4 md:translate-x-0">
            <div class="flex justify-between items-center mb-4">
                <h1 class="text-2xl font-bold">Mijn Notities</h1>
                <button id="closeSidebarBtn" class="md:hidden text-gray-400 hover:text-white">
                    <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path></svg>
                </button>
            </div>
            <div class="mb-4">
                <input type="password" id="apiKey" placeholder="Plak API Key hier" class="w-full bg-gray-700 text-white p-2 rounded border border-gray-600 focus:outline-none focus:ring-2 focus:ring-blue-500">
            </div>
            <div id="file-tree" class="flex-grow overflow-y-auto"></div>
            <button id="newNoteBtn" class="mt-4 w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded">
                Nieuwe Notitie
            </button>
        </aside>

        <main class="w-full flex flex-col md:w-3/4">
            <div id="editor-container" class="flex-grow p-2 sm:p-4 flex flex-col hidden">
                <div class="flex justify-between items-center mb-2">
                    <div class="flex items-center">
                         <button id="menuBtn" class="md:hidden mr-2 p-1 text-gray-400 hover:text-white">
                            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"></path></svg>
                        </button>
                        <span id="current-note-path" class="text-gray-400 text-sm truncate"></span>
                    </div>
                    <div>
                        <button id="saveBtn" class="bg-green-600 hover:bg-green-700 text-white font-bold py-1 px-3 rounded text-sm">Opslaan</button>
                        <button id="deleteBtn" class="bg-red-600 hover:bg-red-700 text-white font-bold py-1 px-3 rounded text-sm ml-2">Verwijderen</button>
                    </div>
                </div>
                <textarea id="note-content" class="w-full flex-grow bg-gray-900 text-gray-200 p-2 sm:p-4 rounded border border-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500 font-mono"></textarea>
            </div>
            <div id="welcome-message" class="flex-grow flex flex-col items-center justify-center p-4">
                 <button id="menuBtnWelcome" class="md:hidden absolute top-4 left-4 p-1 text-gray-400 hover:text-white">
                    <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"></path></svg>
                </button>
                <p class="text-gray-500">Selecteer een notitie om te beginnen of maak een nieuwe aan.</p>
            </div>
        </main>
    </div>

<script>
    // --- ELEMENTEN SELECTEREN ---
    const sidebar = document.getElementById('sidebar');
    const sidebarOverlay = document.getElementById('sidebar-overlay');
    const menuBtn = document.getElementById('menuBtn');
    const menuBtnWelcome = document.getElementById('menuBtnWelcome');
    const closeSidebarBtn = document.getElementById('closeSidebarBtn');
    
    const apiKeyInput = document.getElementById('apiKey');
    const fileTreeContainer = document.getElementById('file-tree');
    const newNoteBtn = document.getElementById('newNoteBtn');
    const editorContainer = document.getElementById('editor-container');
    const welcomeMessage = document.getElementById('welcome-message');
    const currentNotePathEl = document.getElementById('current-note-path');
    const noteContentEl = document.getElementById('note-content');
    const saveBtn = document.getElementById('saveBtn');
    const deleteBtn = document.getElementById('deleteBtn');

    let currentPath = null;
    let debounceTimer;

    // --- MOBIELE SIDEBAR LOGICA ---
    function openSidebar() {
        sidebar.classList.remove('-translate-x-full');
        sidebarOverlay.classList.remove('hidden');
    }

    function closeSidebar() {
        sidebar.classList.add('-translate-x-full');
        sidebarOverlay.classList.add('hidden');
    }

    [menuBtn, menuBtnWelcome].forEach(btn => btn.addEventListener('click', openSidebar));
    [closeSidebarBtn, sidebarOverlay].forEach(el => el.addEventListener('click', closeSidebar));

    // --- API & APP LOGICA ---
    const getApiKey = () => apiKeyInput.value.trim();

    async function apiFetch(endpoint, options = {}) {
        // ... (deze functie blijft ongewijzigd)
    }

    function renderTree(nodes, level = 0) {
        // ... (deze functie blijft ongewijzigd)
    }

    async function loadNoteList() {
        // ... (deze functie blijft ongewijzigd)
    }

    async function loadNoteContent(path) {
        try {
            const data = await apiFetch(`/notes/${path}`);
            currentPath = path;
            currentNotePathEl.textContent = path;
            noteContentEl.value = data.content;
            editorContainer.classList.remove('hidden');
            welcomeMessage.classList.add('hidden');

            // Belangrijk voor mobiel: sluit de sidebar na het selecteren van een notitie
            if (window.innerWidth < 768) {
                closeSidebar();
            }
        } catch (e) {
            console.error('Kon notitie niet laden.', e);
        }
    }

    async function saveNote() {
        // ... (deze functie blijft ongewijzigd)
    }

    async function deleteNote() {
        // ... (deze functie blijft ongewijzigd)
    }

    // --- EVENT LISTENERS ---
    newNoteBtn.addEventListener('click', async () => {
        // ... (deze functie blijft ongewijzigd)
    });
    
    apiKeyInput.addEventListener('input', () => {
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(loadNoteList, 500);
    });

    fileTreeContainer.addEventListener('click', (e) => {
        if (e.target.tagName === 'A') {
            e.preventDefault();
            loadNoteContent(e.target.dataset.path);
        }
    });

    saveBtn.addEventListener('click', saveNote);
    deleteBtn.addEventListener('click', deleteNote);

    fileTreeContainer.innerHTML = '<p class="text-gray-500">Voer je API key in om notities te laden.</p>';
</script>
</body>
</html>
EOF
echo "-> ./apps/obsidian/templates/index.html aangemaakt."

cat > ./automation/homeassistant/configuration.yaml << 'EOF'
# Loads default set of integrations. Do not remove.
default_config:

# Load frontend themes from the themes folder
frontend:
  themes: !include_dir_merge_named themes

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.20.0.0/16 
EOF
echo "-> ./automation/homeassistant/configuration.yaml aangemaakt."

# --- De rest van je script ---
echo "[3/4] Correcte permissies instellen..."
sudo chown -R 1000:1000 ./automation/n8n/
sudo chown -R 1000:1000 ./apps/obsidian/
sudo chown -R 33:33 ./apps/web/public/html/ 
sudo chown -R 33:33 $HOME/appdock/nextcloud/html
sudo chown -R 33:33 ./apps/nextcloud/html/
sudo chown -R 1883:1883 ./automation/mqtt/data/
sudo chown -R 1883:1883 ./automation/mqtt/log/
sudo chown -R root:root ./automation/homeassistant/
sudo chmod 0700 ./automation/mqtt/config/pwdfile

echo "[4/4] Controleren op .env bestand..."
if [ ! -f ./.env ]; then
    echo "-> .env bestand niet gevonden. Aanmaken vanuit example.env..."
    cp example.env .env
    echo "BELANGRIJK: Open het '.env' bestand en vul je eigen tokens en domeinen in!"
else
    echo "-> .env bestand al aanwezig."
fi
echo ""
echo "--- ✅ Setup voltooid! ---"
echo "Je kunt de services nu starten met: docker compose up -d"
echo ""