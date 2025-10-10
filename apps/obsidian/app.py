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
