# Puts the website files into the "site" folder that Cloudflare publishes.
mkdir -p site/app
cp index.html sw.js _headers manifest.webmanifest favicon.ico favicon.svg favicon-32.png apple-touch-icon.png icon-192.png icon-512.png site/
cp app.html site/app/index.html
