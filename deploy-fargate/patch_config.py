"""
Fix for: [json.exception.type_error.302] type must be number, but is number

ROOT CAUSE: The HuggingFace repo momosl/whisper-wolof-v2-ct2 ships a transformers-format
config.json (with begin_suppress_tokens, d_model, etc.) but CTranslate2 expects its OWN
config.json format with suppress_ids, suppress_ids_begin, alignment_heads, lang_ids.

When CTranslate2 tries to iterate over _model->config["suppress_ids"] and the field is
missing/null, nlohmann JSON throws type_error.302.

FIX: Overwrite config.json with correct CTranslate2 format.
"""
import json

f = "/opt/model/config.json"
ct2_config = {
    "suppress_ids": [
        1, 2, 7, 8, 9, 10, 14, 25, 26, 27, 28, 29, 31, 58, 59, 60, 61, 62,
        63, 90, 91, 92, 93, 359, 503, 522, 542, 873, 893, 902, 918, 922, 931,
        1350, 1853, 1982, 2460, 2627, 3246, 3253, 3268, 3536, 3846, 3961,
        4183, 4667, 6585, 6647, 7273, 9061, 9383, 10428, 10929, 11938, 12033,
        12331, 12562, 13793, 14157, 14635, 15265, 15618, 16553, 16604, 18362,
        18956, 20075, 21675, 22520, 26130, 26161, 26435, 28279, 29464, 31650,
        32302, 32470, 36865, 42863, 47425, 49870, 50254, 50258, 50359, 50360,
        50361, 50362, 50363
    ],
    "suppress_ids_begin": [220, 50257],
    "alignment_heads": [
        [7, 0], [10, 17], [12, 18], [13, 12], [16, 1],
        [17, 14], [19, 11], [21, 4], [24, 1], [25, 6]
    ],
    "lang_ids": list(range(50259, 50359))
}
json.dump(ct2_config, open(f, "w"), indent=2)
print("CTranslate2 config.json written OK")
