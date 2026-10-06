import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
DATA = {"45421095": {"number":{"length":16,"luhn":True},"scheme":"visa","type":"debit","brand":"Visa Classic","prepaid":False,
        "country":{"numeric":"826","alpha2":"GB","name":"United Kingdom","currency":"GBP"},
        "bank":{"name":"MOCK BANK PLC","url":"www.mockbank.example","phone":"0800 000 000","city":"London"}},
        "555555": {"scheme":"mastercard","type":"credit","country":{"alpha2":"US","name":"United States"},"bank":{"name":"MOCK US BANK"}}}
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        iin=self.path.strip('/')
        if iin in DATA:
            body=json.dumps(DATA[iin]).encode(); self.send_response(200)
        else:
            body=b'{"error":"not found"}'; self.send_response(404)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
