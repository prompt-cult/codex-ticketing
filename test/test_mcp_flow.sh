#!/bin/bash
# MCP flow test for codex-ticketing (Streamable HTTP) — parity with
# opencode-ticketing v2.2.5: JSON output shapes, reference envelope codes,
# corrected_call self-healing, supersede soft-delete + include_deleted.
# Usage: ./test/test_mcp_flow.sh [PORT]
set -e
PORT=${1:-8099}
BASE="http://127.0.0.1:${PORT}/mcp"
SID_A="ses_test_0001"
SID_B="ses_test_0002"

jget() { # $1 = json, $2 = python expr
  echo "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"
}

call() { # $1 = id, $2 = json rpc body (raw json)
  curl -s --max-time 10 -X POST "$BASE" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -H "Mcp-Session-Id: $MPID" \
    -d "$2"
}

toolcall() { # $1 = id, $2 = name, $3 = args json
  call "$1" "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}"
}

# result text of a tool call
rtext() { # $1 = json rpc response
  jget "$1" "d['result']['content'][0]['text']"
}

# result parsed as JSON (for JSON-shaped results)
rjson() { # $1 = json rpc response
  jget "$1" "json.dumps(json.loads(d['result']['content'][0]['text']))"
}

# error envelope code from an isError result
ecode() { # $1 = json rpc response
  jget "$1" "d['result']['content'][0]['text'].split(':')[0]"
}

echo "== server info =="
curl -s --max-time 5 http://127.0.0.1:${PORT}/ | python3 -m json.tool

echo "== initialize =="
INIT=$(curl -s -D /tmp/tr_headers.txt -X POST "$BASE" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"flowtest","version":"1.0.0"}}}')
echo "$INIT" | python3 -m json.tool
MPID=$(awk 'tolower($1)=="mcp-session-id:"{gsub("\r","");print $2}' /tmp/tr_headers.txt)
echo "session=$MPID"

echo "== tools/list =="
call 2 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | python3 -c 'import json,sys; d=json.load(sys.stdin); print([t["name"] for t in d["result"]["tools"]])'

echo "== ticket_add (type=bug) =="
ADD=$(toolcall 3 ticket_add "{\"todo\":\"L1 flow test ticket\",\"md_content\":\"Verifying the MCP server end-to-end.\",\"session_id\":\"$SID_A\",\"type\":\"bug\"}")
echo "$ADD" | python3 -m json.tool
TNUM=$(rjson "$ADD" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["id"])')
echo "ticket=$TNUM"
jget "$ADD" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["session_id"]=="ses_test_0001"; assert d["ticket"]["type"]=="bug"; assert d["ticket"]["status"]=="pending"; print("add-shape ok")'

echo "== ticket_get =="
GET=$(toolcall 4 ticket_get "{\"id\":$TNUM}")
jget "$GET" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["id"]==int("'$TNUM'"); assert "comments" not in r; print("get-row-shape ok")'

echo "== ticket_list (session, type=bug) =="
LIST=$(toolcall 5 ticket_list "{\"session_id\":\"$SID_A\",\"type\":\"bug\"}")
jget "$LIST" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; a=json.load(sys.stdin); assert isinstance(a,list) and len(a)>=1 and a[0]["type"]=="bug"; print("list-shape ok")'

echo "== ticket_comment =="
CMT=$(toolcall 6 ticket_comment "{\"id\":$TNUM,\"content\":\"go: MCP flow green\",\"session_id\":\"$SID_A\"}")
jget "$CMT" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; c=json.load(sys.stdin); assert c["ticket_id"]==int("'$TNUM'"); assert c["author_session_id"]=="ses_test_0001"; print("comment-shape ok")'
echo "== ticket_get (comments block) =="
GET2=$(toolcall 18 ticket_get "{\"id\":$TNUM}")
jget "$GET2" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; t=sys.stdin.read(); assert "--- comments (chronological) ---" in t; assert "go: MCP flow green" in t; print("get-comments-block ok")'

echo "== ticket_status (owner) =="
ST=$(toolcall 7 ticket_status "{\"id\":$TNUM,\"session_id\":\"$SID_A\",\"status\":\"in_progress\"}")
jget "$ST" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="in_progress"; assert r["last_actor"]=="ses_test_0001"; print("status-shape ok")'

echo "== error envelope: bad type =="
E1=$(toolcall 8 ticket_add "{\"todo\":\"bad type\",\"session_id\":\"$SID_A\",\"type\":\"banana\"}")
[ "$(ecode "$E1")" = "E_ADD_BAD_TYPE" ] || { echo "FAIL code: $(ecode "$E1")"; exit 1; }
jget "$E1" "d['result']['content'][0]['text']" | grep -q 'Corrected call' && echo "bad-type envelope ok"

echo "== error envelope: missing todo =="
E2=$(toolcall 9 ticket_add "{\"session_id\":\"$SID_A\"}")
[ "$(ecode "$E2")" = "E_ADD_MISSING_TODO" ] && echo "missing-todo envelope ok"

echo "== error envelope: extra property =="
E3=$(toolcall 10 ticket_add "{\"todo\":\"x\",\"session_id\":\"$SID_A\",\"bogus\":1}")
[ "$(ecode "$E3")" = "E_ADD_EXTRA_PROPERTY" ] && echo "extra-prop envelope ok"

echo "== error envelope: bad id type =="
E4=$(toolcall 11 ticket_get "{\"id\":\"abc\"}")
[ "$(ecode "$E4")" = "E_GET_BAD_ID" ] && echo "bad-id envelope ok"

echo "== error envelope: missing session on list =="
E5=$(toolcall 12 ticket_list "{}")
[ "$(ecode "$E5")" = "E_LIST_MISSING_SESSION_ID" ] || { echo "FAIL code: $(ecode "$E5")"; exit 1; }
jget "$E5" "d['result']['content'][0]['text']" | grep -q '"all": true' && echo "list-session envelope ok"

echo "== error envelope: status forbidden (wrong owner) =="
E6=$(toolcall 13 ticket_status "{\"id\":$TNUM,\"session_id\":\"$SID_B\",\"status\":\"completed\"}")
[ "$(ecode "$E6")" = "E_STATUS_REFUSED" ] || { echo "FAIL code: $(ecode "$E6")"; exit 1; }
jget "$E6" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; t=sys.stdin.read(); cc=json.loads(t.split("Corrected call:\n")[1]); assert cc["session_id"]=="ses_test_0001"; print("refused-selfheal ok")'

echo "== error envelope: comment too long =="
LONG=$(python3 -c 'print("x"*1001)')
E7=$(toolcall 14 ticket_comment "{\"id\":$TNUM,\"content\":\"$LONG\",\"session_id\":\"$SID_A\"}")
[ "$(ecode "$E7")" = "E_COMMENT_TOO_LONG" ] && echo "comment-long envelope ok"

echo "== supersede -> soft-delete hidden, include_deleted reveals =="
SS=$(toolcall 15 ticket_status "{\"id\":$TNUM,\"session_id\":\"$SID_A\",\"status\":\"superseded\"}")
jget "$SS" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="superseded" and r["deleted"]==1; print("superseded deleted=1")'
HIDDEN=$(toolcall 16 ticket_list "{\"session_id\":\"$SID_A\"}")
jget "$HIDDEN" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; a=json.load(sys.stdin); assert all(t["deleted"]==0 for t in a); print("hidden from default list ok")'
REVEAL=$(toolcall 17 ticket_list "{\"session_id\":\"$SID_A\",\"include_deleted\":true}")
jget "$REVEAL" "d['result']['content'][0]['text']" | python3 -c 'import json,sys; a=json.load(sys.stdin); assert any(t["deleted"]==1 and t["status"]=="superseded" for t in a); print("include_deleted reveals ok")'

echo "ALL FLOW CHECKS DONE"
