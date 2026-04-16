import os
from flask import Flask

app = Flask(__name__)

ENVIRONMENT = os.environ.get('ENVIRONMENT', 'Local')

@app.route('/')
def hello():
    return f"""
    <html>
        <body style="font-family: sans-serif; text-align: center; margin-top: 50px;">
            <h1>🚀 Hello from GKE Autopilot!</h1>
            <h2>Current Environment: <span style="color: blue;">{ENVIRONMENT}</span></h2>
        </body>
    </html>
    """

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=8080)