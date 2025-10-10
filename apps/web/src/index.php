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
