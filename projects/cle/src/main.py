from fasthtml import common as fh
import os
import secrets

secret = os.getenv('SESSION_SECRET') or secrets.token_bytes(20)

app,rt = fh.fast_app(
    live=os.getenv('LIVE', False),
    secret_key = secret)

@rt('/')
def get(): 
    return fh.Titled("FastHTML", fh.Div(fh.P('Hello from FastHTML on AWS Lambda!')))


fh.serve()