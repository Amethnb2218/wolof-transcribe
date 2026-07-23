import json

f = "/opt/model/config.json"
c = json.load(open(f))
c["begin_suppress_tokens"] = c.get("begin_suppress_tokens") or []
c.pop("max_length", None)
json.dump(c, open(f, "w"), indent=2)

f2 = "/opt/model/generation_config.json"
g = json.load(open(f2))
g.pop("forced_decoder_ids", None)
json.dump(g, open(f2, "w"), indent=2)

print("Config patched OK")
