#!/bin/bash
set -e

setup_downloader() {
    echo "--- [2/2] Service 'downloader' instellen ---"
    local downloader_dir="./apps/downloader"
    local vendor_dir="${downloader_dir}/vendor/yt-dlp"
    local config_dir="${downloader_dir}/config"

    # Maak alle benodigde mappen in één keer aan
    mkdir -p "${vendor_dir}"
    mkdir -p "${downloader_dir}/downloads/"{videos,images,documents,other}
    mkdir -p "${downloader_dir}/templates"
    mkdir -p "${config_dir}"

    # --- ARCHITECTUUR DETECTIE VOOR YT-DLP ---
    echo "-> Detecteren van CPU-architectuur..."
    ARCH=$(uname -m)
    YT_DLP_URL=""
    if [[ "$ARCH" == "x86_64" ]]; then
        echo "--> x86_64 (Intel/AMD) gedetecteerd."
        YT_DLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux"
    elif [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
        echo "--> aarch64 (ARM) gedetecteerd (Raspberry Pi / Apple Silicon)."
        YT_DLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux_aarch64"
    else
        echo "❌ Fout: Niet-ondersteunde architectuur: $ARCH"
        exit 1
    fi

    echo "-> Downloaden van de juiste yt-dlp versie..."
    # We slaan het altijd op als 'yt-dlp_linux' zodat de Python code niet hoeft te veranderen
    curl -L "$YT_DLP_URL" -o "${vendor_dir}/yt-dlp_linux"
    chmod +x "${vendor_dir}/yt-dlp_linux"
    echo "--> yt-dlp gedownload en uitvoerbaar gemaakt."

    # Maak Dockerfile aan
    cat > ./apps/downloader/Dockerfile << 'EOF'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN chmod +x vendor/yt-dlp/yt-dlp_linux
EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "4", "--timeout", "120", "api:app"]
EOF
    echo "-> Dockerfile voor downloader aangemaakt."

    # Maak requirements.txt aan
    cat > ./apps/downloader/requirements.txt << 'EOF'
Flask
python-dotenv
gunicorn
redis
EOF
    echo "-> requirements.txt voor downloader aangemaakt."

    # Maak downloader.py aan
    cat > ./apps/downloader/downloader.py << 'EOF'
import subprocess
import os
import shutil
import glob
import json
import platform
from pathlib import Path

# Detecteer OS en kies de juiste executable
OS_TYPE = platform.system()
YT_DLP_EXEC = None
# Pad is relatief aan de WORKDIR (/app) in de Docker container
if OS_TYPE == "Linux":
    YT_DLP_EXEC = os.path.join(os.getcwd(), 'vendor/yt-dlp/yt-dlp_linux')
elif OS_TYPE == "Darwin": # macOS
    YT_DLP_EXEC = os.path.join(os.getcwd(), 'vendor/yt-dlp/yt-dlp_macos')

def get_output_subdirectory(final_output_path):
    """Bepaalt de juiste submap op basis van de bestandsextensie."""
    ext = Path(final_output_path).suffix.lower().lstrip('.')
    if ext in ['mp4', 'mkv', 'webm', 'mov', 'avi', 'flv']: return 'videos'
    if ext in ['jpg', 'jpeg', 'png', 'webp', 'svg']: return 'images'
    if ext in ['gif']: return 'gifs'
    if ext in ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'txt']: return 'documents'
    return 'other'

def find_downloaded_parts(directory):
    """
    Scant een map op de gedownloade bestanden van yt-dlp.
    Returned de bestanden die potentieel video, audio of gemerged zijn.
    """
    video_parts = glob.glob(os.path.join(directory, 'media.*.mp4')) + glob.glob(os.path.join(directory, 'media.*.webm'))
    audio_parts = glob.glob(os.path.join(directory, 'media.*.m4a')) + glob.glob(os.path.join(directory, 'media.*.opus'))
    merged_file = glob.glob(os.path.join(directory, 'media.mp4')) + glob.glob(os.path.join(directory, 'media.webm'))
    return video_parts, audio_parts, merged_file

def download_video(url, base_output_dir, redis_client, task_id):
    """
    Downloadt, her-codeert en sorteert een video. Update de status in Redis.
    """
    print(f"--- download_video() aangeroepen voor {url} (Taak-ID: {task_id}) ---")

    # Bepaal het pad naar de yt-dlp executable
    YT_DLP_EXEC = 'vendor/yt-dlp/yt-dlp_linux' if platform.system() == "Linux" else 'vendor/yt-dlp/yt-dlp_macos'
    if not os.path.exists(YT_DLP_EXEC):
        return {'success': False, 'error': "yt-dlp executable niet gevonden."}
    
    ffmpeg_exec = shutil.which('ffmpeg')
    if not ffmpeg_exec:
        return {'success': False, 'error': "ffmpeg is niet geïnstalleerd in de container."}

    temp_dir = os.path.join(base_output_dir, "temp_download")
    
    try:
        def update_status(status_message):
            try:
                redis_client.set(f"task:{task_id}", json.dumps({'status': status_message}))
                print(f"  -> Redis status bijgewerkt: {status_message}")
            except Exception as e:
                print(f"  !! FOUT bij bijwerken Redis status: {e}")

        update_status('starting')
        if os.path.exists(temp_dir): shutil.rmtree(temp_dir)
        os.makedirs(temp_dir, exist_ok=True)

        base_command = [YT_DLP_EXEC, '--restrict-filenames', '--no-warnings']
        cookie_file_path = '/config/cookies.txt'
        
        # --- DE CRUCIALE WIJZIGING ---
        if os.path.exists(cookie_file_path):
            print("INFO: Cookie-bestand gevonden, wordt gebruikt.")
            # Definieer een tijdelijk pad voor de cookie-jar BINNEN de temp-map
            temp_cookie_jar = os.path.join(temp_dir, 'cookiejar.txt')
            # Kopieer de originele cookies naar de tijdelijke jar
            shutil.copy(cookie_file_path, temp_cookie_jar)
            # Vertel yt-dlp om dit tijdelijke, beschrijfbare bestand te gebruiken
            base_command.extend(['--cookies', temp_cookie_jar])
        
        update_status('fetching_metadata')
        info_command = base_command + ['--dump-json', url]
        metadata = json.loads(subprocess.check_output(info_command))
        video_title = metadata.get('title', 'downloaded_video')

        update_status('downloading')
        command_dl = base_command + ['-f', 'bestvideo+bestaudio/best', '-k', '-o', os.path.join(temp_dir, 'media.%(ext)s'), url]
        subprocess.run(command_dl, check=True, capture_output=True, text=True)

        update_status('processing')
        video_parts, audio_parts, merged_file = find_downloaded_parts(temp_dir)
        final_file_to_move = None

        if merged_file or (video_parts and audio_parts):
            input_file = merged_file[0] if merged_file else video_parts[0]
            audio_input_args = ['-i', audio_parts[0]] if audio_parts else []
            
            intermediate_output_path = os.path.join(temp_dir, f"{video_title}.mp4")
            
            command_reencode = [ffmpeg_exec, '-i', input_file] + audio_input_args + [
                '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
                '-c:a', 'aac', '-pix_fmt', 'yuv420p', '-y', intermediate_output_path
            ]
            subprocess.run(command_reencode, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            final_file_to_move = intermediate_output_path
        else:
            raise FileNotFoundError("Kon geen bruikbare videobestanden vinden na download.")

        update_status('sorting')
        target_subdir = get_output_subdirectory(final_file_to_move)
        final_destination_dir = os.path.join(base_output_dir, target_subdir)
        os.makedirs(final_destination_dir, exist_ok=True)
        final_filename = f"{video_title}{Path(final_file_to_move).suffix}"
        final_filepath = os.path.join(final_destination_dir, final_filename)
        shutil.move(final_file_to_move, final_filepath)
        
        relative_filepath = os.path.relpath(final_filepath, base_output_dir)
        return {'success': True, 'data': metadata, 'filepath': relative_filepath}

    except subprocess.CalledProcessError as e:
        error_msg = f"Fout in extern commando: {e.stderr}"
        return {'success': False, 'error': error_msg}
    except Exception as e:
        error_msg = f"Een onverwachte fout: {str(e)}"
        return {'success': False, 'error': error_msg}
    finally:
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir)
            print("--- Tijdelijke bestanden opgeruimd ---")

EOF
    echo "-> downloader.py aangemaakt."

    # Maak api.py aan
    cat > ./apps/downloader/api.py << 'EOF'
import os
import uuid
import json
import redis
import platform
import subprocess
from functools import wraps
from threading import Thread
from flask import Flask, request, jsonify, render_template, send_from_directory, url_for
from downloader import download_video
from dotenv import load_dotenv

load_dotenv()
app = Flask(__name__)
BEARER_TOKEN = os.environ.get('DOWNLOADER_BEARER_TOKEN')
DOWNLOADS_DIR = '/downloads'

# Maak verbinding met de Redis-service
redis_client = redis.Redis(host='redis', port=6379, decode_responses=True)

# Bepaal het pad naar yt-dlp voor de /api/info endpoint
OS_TYPE = platform.system()
YT_DLP_EXEC_PATH_API = None
if OS_TYPE == "Linux":
    YT_DLP_EXEC_PATH_API = os.path.join('/app', 'vendor/yt-dlp/yt-dlp_linux')
elif OS_TYPE == "Darwin": # macOS
    YT_DLP_EXEC_PATH_API = os.path.join('/app', 'vendor/yt-dlp/yt-dlp_macos')


def require_api_key(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not BEARER_TOKEN: 
            return jsonify({"error": "Configuration Error", "message": "API Key is not configured on the server."}), 500
        auth_header = request.headers.get('Authorization')
        if not auth_header or not auth_header.startswith('Bearer '):
            return jsonify({"error": "Unauthorized", "message": "Authorization header is missing or invalid."}), 401
        provided_key = auth_header.split(' ')[1]
        if provided_key != BEARER_TOKEN:
            return jsonify({"error": "Forbidden", "message": "Invalid API Key."}), 403
        return f(*args, **kwargs)
    return decorated_function

def run_download_in_background(url, task_id):
    """Functie die de download draait en de status in Redis update."""
    print(f"Background task {task_id} started for {url}")
    # De download_video functie werkt nu zelf de Redis status bij
    result = download_video(url, DOWNLOADS_DIR, redis_client, task_id) 
    
    # Als de download_video al de final status heeft gezet, hoeven we hier niets te doen
    # Anders zorgen we dat er een finished status is
    current_status_json = redis_client.get(f"task:{task_id}")
    if not current_status_json or json.loads(current_status_json).get('status') != 'finished':
        final_status = {'status': 'finished', 'result': result}
        redis_client.setex(f"task:{task_id}", 600, json.dumps(final_status))
    print(f"Background task {task_id} finished.")

def start_download_task(url):
    """Maakt een nieuwe taak aan, start de thread en geeft de taakinfo terug."""
    task_id = str(uuid.uuid4())
    # Sla de initiële status op in Redis, niet in een lokale dict
    redis_client.set(f"task:{task_id}", json.dumps({'status': 'queued'})) 
    
    thread = Thread(target=run_download_in_background, args=(url, task_id), daemon=True)
    thread.start()
    
    return {
        'status': 'queued',
        'task_id': task_id,
        'status_url': url_for('get_status', task_id=task_id, _external=False)
    }

# --- GUI Routes ---
@app.route('/', methods=['GET'])
def index():
    file_list = []
    if os.path.exists(DOWNLOADS_DIR):
        for subdir, _, files in os.walk(DOWNLOADS_DIR):
            for file in files:
                if not file.startswith('.'):
                    filepath = os.path.join(subdir, file)
                    relative_path = os.path.relpath(filepath, DOWNLOADS_DIR)
                    file_list.append(relative_path)
    return render_template('index.html', files=sorted(file_list, reverse=True))


@app.route('/files/<path:filepath>')
def serve_file(filepath):
    return send_from_directory(DOWNLOADS_DIR, filepath, as_attachment=True)


# --- API Routes ---
@app.route('/api/info', methods=['GET'])
@require_api_key
def get_video_info():
    url = request.args.get('url')
    if not url:
        return jsonify({"error": "Bad Request", "message": "URL query parameter is missing."}), 400

    if not YT_DLP_EXEC_PATH_API or not os.path.exists(YT_DLP_EXEC_PATH_API):
        return jsonify({"error": "Configuration Error", "message": f"yt-dlp executable niet gevonden voor dit OS ({OS_TYPE})."}), 500

    try:
        base_command = [YT_DLP_EXEC_PATH_API, '--restrict-filenames']
        cookie_file_path = '/config/cookies.txt'
        if os.path.exists(cookie_file_path):
            base_command.extend(['--cookies', cookie_file_path])

        info_command = base_command + ['--dump-json', url]
        result = subprocess.run(info_command, check=True, capture_output=True, text=True)
        
        video_info = json.loads(result.stdout)
        return jsonify(video_info), 200

    except subprocess.CalledProcessError as e:
        error_details = e.stderr
        error_msg = f"Fout bij ophalen video info: {error_details[:500]}..."
        if "unauthorized" in error_details.lower() or "login" in error_details.lower():
            error_msg = "Kan info niet ophalen (Unauthorized). Login vereist. Cookies.txt is mogelijk verlopen of incorrect."
        return jsonify({"error": error_msg}), 500
    except Exception as e:
        return jsonify({"error": f"Onverwachte fout bij ophalen info: {str(e)}"}), 500


@app.route('/api/download', methods=['POST'])
@require_api_key
def handle_api_download():
    data = request.json
    if not data or 'url' not in data: 
        return jsonify({"error": "Bad Request", "message": "Request body must contain 'url' key."}), 400
    
    task_info = start_download_task(data['url'])
    return jsonify(task_info), 202

@app.route('/status/<string:task_id>', methods=['GET'])
@require_api_key # Beveilig ook de status-endpoint
def get_status(task_id):
    """Endpoint om de status van een specifieke taak op te vragen."""
    task_json = redis_client.get(f"task:{task_id}")
    if not task_json:
        return jsonify({'status': 'not_found'}), 404
    return jsonify(json.loads(task_json))

EOF
    echo "-> api.py voor downloader aangemaakt."

    # Maak de HTML template voor de GUI
    cat > ./apps/downloader/templates/index.html << 'EOF'
    <!DOCTYPE html>
<html lang="nl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Plongo Downloader</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        /* Voorkom lelijke scrollbar op de body */
        html { overflow-y: scroll; }
    </style>
</head>
<body class="bg-gray-900 text-gray-200 font-sans antialiased">
    <div class="container mx-auto p-4 md:p-8 max-w-4xl">
        <header class="text-center mb-8">
            <h1 class="text-4xl font-bold text-white">Plongo Downloader</h1>
            <p class="text-gray-400 mt-2">Plak een link om een video of afbeelding te downloaden.</p>
        </header>

        <div class="w-full mx-auto bg-gray-800 rounded-lg shadow-lg p-6 border border-gray-700">
            <form id="download-form">
                <div class="mb-4">
                    <label for="api-key-input" class="sr-only">API Key</label>
                    <input type="password" id="api-key-input" placeholder="Plak je DOWNLOADER_BEARER_TOKEN hier" class="w-full bg-gray-700 text-white p-3 rounded-md border border-gray-600 focus:outline-none focus:ring-2 focus:ring-blue-500" required>
                </div>
                <div class="flex items-center">
                    <label for="url-input" class="sr-only">URL</label>
                    <input type="url" name="url" id="url-input" placeholder="https://..." class="w-full bg-gray-700 text-white p-3 rounded-l-md border-t border-b border-l border-gray-600 focus:outline-none focus:ring-2 focus:ring-blue-500" required>
                    <button type="submit" id="submit-button" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-3 px-6 rounded-r-md transition-colors duration-200 disabled:bg-gray-500 disabled:cursor-not-allowed">Download</button>
                </div>
            </form>
            <div id="status-container" class="mt-4 p-4 rounded-md min-h-[6rem] hidden flex items-center justify-center"></div>
        </div>

        <section class="mt-12">
            <h2 class="text-2xl font-semibold text-white mb-4">Gedownloade Bestanden</h2>
            <div class="bg-gray-800 rounded-lg shadow-lg border border-gray-700">
                <ul id="file-list" class="divide-y divide-gray-700">
                    {% if files %}
                        {% for file in files %}
                            <li class="p-4 flex justify-between items-center hover:bg-gray-700/50 transition-colors duration-200">
                                <span class="font-mono text-sm text-gray-300 break-all">{{ file }}</span>
                                <a href="{{ url_for('serve_file', filepath=file) }}" class="text-blue-400 hover:text-blue-300 text-sm font-semibold ml-4 flex-shrink-0">Download</a>
                            </li>
                        {% endfor %}
                    {% else %}
                        <li id="no-files-message" class="p-4 text-center text-gray-500">Nog geen bestanden gedownload.</li>
                    {% endif %}
                </ul>
            </div>
        </section>
    </div>
    
    <script>
        const form = document.getElementById('download-form');
        const apiKeyInput = document.getElementById('api-key-input');
        const urlInput = document.getElementById('url-input');
        const submitButton = document.getElementById('submit-button');
        const statusContainer = document.getElementById('status-container');
        const fileList = document.getElementById('file-list');
        const noFilesMessage = document.getElementById('no-files-message');
        let pollingInterval;

        apiKeyInput.value = sessionStorage.getItem('downloaderApiKey') || '';
        apiKeyInput.addEventListener('input', () => {
            sessionStorage.setItem('downloaderApiKey', apiKeyInput.value);
        });

        const showError = (message) => {
            statusContainer.className = 'mt-4 p-4 rounded-md min-h-[6rem] flex items-center justify-center bg-red-900/50 border border-red-700';
            statusContainer.innerHTML = `<div class="text-center"><p class="text-red-300 font-bold">✗ Fout</p><p class="text-sm text-red-400">${message}</p></div>`;
            statusContainer.classList.remove('hidden');
            submitButton.disabled = false;
            submitButton.textContent = 'Download';
            if(pollingInterval) clearInterval(pollingInterval);
        };

        const updateStatus = (task) => {
            let statusText = '', subText = '', classes = '';
            switch (task.status) {
                case 'queued':
                    classes = 'bg-yellow-900/50 border border-yellow-700';
                    statusText = '<p class="text-yellow-300 font-bold">In de wachtrij...</p>';
                    subText = '<p class="text-sm text-yellow-400">Wachten op een vrije worker.</p>';
                    break;
                case 'fetching_metadata':
                case 'downloading':
                    classes = 'bg-blue-900/50 border border-blue-700';
                    statusText = '<p class="text-blue-300 font-bold">Downloaden...</p>';
                    subText = `<p class="text-sm text-blue-400">Status: ${task.status}</p>`;
                    break;
                case 'encoding':
                case 'sorting':
                case 'processing':
                    classes = 'bg-purple-900/50 border border-purple-700';
                    statusText = '<p class="text-purple-300 font-bold">Verwerken...</p>';
                    subText = `<p class="text-sm text-purple-400">Status: ${task.status}</p>`;
                    break;
                case 'finished':
                    if (task.result && task.result.success) {
                        classes = 'bg-green-900/50 border border-green-700';
                        statusText = '<p class="text-green-300 font-bold">✓ Succes!</p>';
                        subText = `<p class="text-sm text-gray-300">Bestand gedownload: ${task.result.data.title}</p>`;
                    } else {
                        classes = 'bg-red-900/50 border border-red-700';
                        statusText = '<p class="text-red-300 font-bold">✗ Fout opgetreden</p>';
                        subText = `<p class="text-sm text-red-400 font-mono">${task.result.error}</p>`;
                    }
                    break;
                default:
                    classes = 'bg-gray-700 border border-gray-600';
                    statusText = `<p>Onbekende status: ${task.status}</p>`;
            }
            statusContainer.className = `mt-4 p-4 rounded-md min-h-[6rem] flex items-center justify-center ${classes}`;
            statusContainer.innerHTML = `<div class="text-center">${statusText}${subText}</div>`;
        };
        
        const pollStatus = async (statusUrl, apiKey) => {
            try {
                const response = await fetch(statusUrl, { headers: { 'Authorization': `Bearer ${apiKey}` } });
                if (!response.ok) throw new Error(`Status check mislukt: ${response.status}`);
                const task = await response.json();
                updateStatus(task);

                if (task.status === 'finished') {
                    clearInterval(pollingInterval);
                    submitButton.disabled = false;
                    submitButton.textContent = 'Download';
                    
                    // --- DE BELANGRIJKSTE WIJZIGING ---
                    if (task.result && task.result.success) {
                        // Creëer een nieuw lijst-item en voeg het VOORAAN toe
                        const newFile = task.result.filepath;
                        const newLi = document.createElement('li');
                        newLi.className = 'p-4 flex justify-between items-center hover:bg-gray-700/50 transition-colors duration-200';
                        newLi.innerHTML = `
                            <span class="font-mono text-sm text-gray-300 break-all">${newFile}</span>
                            <a href="/files/${newFile}" class="text-blue-400 hover:text-blue-300 text-sm ml-4 flex-shrink-0">Download</a>
                        `;
                        fileList.prepend(newLi);
                        
                        // Verberg de "nog geen bestanden" boodschap als die zichtbaar was
                        if (noFilesMessage) {
                            noFilesMessage.style.display = 'none';
                        }
                    }
                }
            } catch (error) {
                console.error('Polling error:', error);
                showError('Kon de status niet ophalen of er is een netwerkfout.');
            }
        };

        form.addEventListener('submit', async function(event) {
            event.preventDefault();
            const url = urlInput.value;
            const apiKey = apiKeyInput.value;
            if (!url || !apiKey) {
                alert('URL en API Key zijn verplicht!');
                return;
            }

            submitButton.disabled = true;
            submitButton.textContent = 'Bezig...';
            statusContainer.className = 'mt-4 p-4 rounded-md h-24 bg-yellow-900/50 border border-yellow-700';
            statusContainer.innerHTML = '<p class="text-yellow-300 font-bold">In de wachtrij...</p><p class="text-sm text-yellow-400">Download wordt gestart.</p>';
            statusContainer.classList.remove('hidden');

            try {
                const response = await fetch('/api/download', {
                    method: 'POST',
                    headers: { 
                        'Content-Type': 'application/json',
                        'Authorization': `Bearer ${apiKey}`
                    },
                    body: JSON.stringify({ url: url })
                });

                if (!response.ok) {
                    const errorData = await response.json();
                    throw new Error(errorData.message || `Serverfout: ${response.status}`);
                }

                const data = await response.json();
                if (data.status_url) {
                    // Start polling
                    pollingInterval = setInterval(() => pollStatus(data.status_url, apiKey), 2000);
                }
            } catch (error) {
                showError(error.message);
            }
        });
    </script>
</body>
</html>
EOF
    echo "-> index.html template voor GUI aangemaakt."

    # Permissies voor de downloads map
    sudo chown -R 1000:1000 "${downloader_dir}/downloads"
    echo "-> Permissies voor downloader ingesteld."
}


backup_n8n() {
    echo "--- 💾 n8n Backup Modus ---"
    local backup_dir="./backups/n8n/$(date +%F_%H-%M-%S)"
    mkdir -p "$backup_dir"
    echo "-> Backup map aangemaakt op host: $backup_dir"
    sudo chown -R 1000:1000 "$backup_dir"
    echo "-> Permissies voor backup map correct ingesteld."
    local container_path="/home/node/backups/$(basename "$backup_dir")"

    echo "-> Workflows exporteren..."
    docker exec -u node plongo_n8n n8n export:workflow --all --output="${container_path}/workflows.json"
    echo "--> Workflows succesvol geëxporteerd."

    echo "-> Credentials (versleuteld) exporteren..."
    docker exec -u node plongo_n8n n8n export:credentials --all --output="${container_path}/credentials.json"
    echo "--> Credentials succesvol geëxporteerd."

    echo "-> Encryption Key veiligstellen..."

    cp ./automation/n8n/config/config "${backup_dir}/encryptionKey.json"
    echo "--> Encryption Key succesvol gekopieerd."

    echo ""
    echo "--- ✅ Backup voltooid! Bestanden staan in: $backup_dir ---"
}

restore_n8n() {
    echo "--- 🔄 n8n Restore Modus ---"

    # Vind de meest recente backup-map
    local latest_backup=$(ls -td ./backups/n8n/*/ | head -n 1)

    if [ -z "$latest_backup" ]; then
        echo "❌ Fout: Geen backup-mappen gevonden in ./backups/n8n/"
        exit 1
    fi

    echo "Meest recente backup gevonden: $latest_backup"
    read -p "Weet je zeker dat je wilt herstellen vanaf deze backup? Huidige workflows/credentials worden mogelijk overschreven. (y/n) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local key_file="${latest_backup}encryptionKey.json"
        local workflows_file="${latest_backup}workflows.json"
        local credentials_file="${latest_backup}credentials.json"

        if [ ! -f "$key_file" ]; then
            echo "❌ Fout: encryptionKey.json niet gevonden in de backup. Herstellen is onmogelijk."
            exit 1
        fi

        echo "-> Stoppen van de n8n container voor een veilige restore..."
        docker compose stop n8n

        echo "-> Encryption Key herstellen..."
        cp "$key_file" ./automation/n8n/config/config
        echo "--> Encryption Key geplaatst."
        
        # Stel permissies opnieuw in
        sudo chown 1000:1000 ./automation/n8n/config/config
        sudo chmod 600 ./automation/n8n/config/config

        echo "-> Starten van n8n om data te importeren..."
        docker compose up -d n8n --force-recreate
        echo "--> Wachten tot n8n volledig is gestart (kan even duren)..."
        sleep 15

        local container_path="/home/node/backups/$(basename "$latest_backup")"

        echo "-> Credentials importeren..."
        docker exec -u node plongo_n8n n8n import:credentials --input="${container_path}/credentials.json"

        echo "-> Workflows importeren..."
        docker exec -u node plongo_n8n n8n import:workflow --input="${container_path}/workflows.json"

        echo ""
        echo "--- ✅ Restore voltooid! ---"
        # docker compose restart n8n ?
    else
        echo "Restore geannuleerd."
    fi
}

# --- FUNCTIE OM EEN SPECIFIEKE SERVICE TE RESETTEN ---
reset_service() {
    local service_name=$1
    local paths_to_delete=()
    local docker_service=$service_name

    # Map service namen naar de bijbehorende mappen
    case "$service_name" in
        "downloader")
            paths_to_delete=("./apps/downloader/")
            ;;
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
            # paths_to_delete=("./apps/nextcloud/" "$HOME/appdock/nextcloud")
            paths_to_delete=("./apps/nextcloud/")
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

case "$1" in
    --downloader)
        setup_downloader
        exit 0
        ;;
    --backup)
        backup_n8n
        exit 0
        ;;
    --restore)
        restore_n8n
        exit 0
        ;;
    --reset)
        if [ -z "$2" ]; then
        reset_full_project
        else
            reset_service "$2"
        fi
        exit 0
        ;;
esac

echo "--- Plongo Setup Script ---"
echo "[1/4] Benodigde mappen aanmaken..."
mkdir -p ./backups/n8n
mkdir -p ./backups/db
mkdir -p ./database
mkdir -p ./automation/n8n/config
mkdir -p ./automation/mqtt/config
mkdir -p ./automation/mqtt/data
mkdir -p ./automation/mqtt/log
# --- Mappen voor de apps ---
mkdir -p ./apps/web/src
mkdir -p ./apps/web/public/html
mkdir -p ./apps/nextcloud/html
mkdir -p ./apps/nextcloud/data
mkdir -p ./apps/obsidian/notes
mkdir -p ./apps/obsidian/templates 
mkdir -p ./automation/homeassistant
# Downloader app mappen
# mkdir -p ./apps/downloader/templates
# mkdir -p ./apps/downloader/vendor/yt-dlp
# mkdir -p ./apps/downloader/downloads/{videos,images,documents,other}
# mkdir -p ./apps/downloader/config
# mkdir -p $HOME/appdock/nextcloud/html
touch ./automation/homeassistant/configuration.yaml
touch ./automation/homeassistant/automations.yaml
touch ./automation/homeassistant/scripts.yaml
touch ./automation/homeassistant/scenes.yaml

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
    -- === Database voor Mqtt ===
    CREATE USER ${MQTT_DB_USER} WITH PASSWORD '${MQTT_DB_PASSWORD}';
    CREATE DATABASE ${MQTT_DB_NAME};
    GRANT ALL PRIVILEGES ON DATABASE ${MQTT_DB_NAME} TO ${MQTT_DB_USER};
    ALTER DATABASE ${MQTT_DB_NAME} OWNER TO ${MQTT_DB_USER};
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

if [ ! -f ./apps/web/src/index.php ]; then
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
else 
    echo "-> ./apps/web/src/index.php bestand al aanwezig."
fi

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
    - 172.18.0.0/16
    - 172.19.0.0/16
    - 172.20.0.0/16
EOF
echo "-> ./automation/homeassistant/configuration.yaml aangemaakt."


# --- De rest van je script ---
echo "[3/4] Correcte permissies instellen..."
sudo chown -R 1000:1000 ./backups/n8n
sudo chown -R 1000:1000 ./automation/n8n/
sudo chown -R 1000:1000 ./apps/obsidian/
sudo chown -R 33:33 ./apps/web/public/html/ 
# sudo chown -R 33:33 $HOME/appdock/nextcloud/html
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