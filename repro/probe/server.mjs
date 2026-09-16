import { createServer } from "node:http";
import { readFileSync } from "node:fs";
const page = readFileSync(new URL("./page.html", import.meta.url));
createServer((req, res) => { res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" }); res.end(page); }).listen(8123, "127.0.0.1");
