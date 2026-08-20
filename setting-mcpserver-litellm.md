# LiteLLM에 MCP 서버 등록하기

LiteLLM 게이트웨이에 MCP 서버를 붙이는 방법만 따로 정리한 문서입니다. 이해 → 요건 →
설정(YAML · UI · API) → 검증 → 운영 순서로, 복사해서 바로 실행할 수 있는 형태로 씁니다.

> **검증 환경**
> LiteLLM **v1.93.0** (`ghcr.io/berriai/litellm:main-stable`), 단일 노드 Docker Compose,
> 업스트림 MCP 서버는 ClickHouse Cloud용 `mcp-clickhouse`(SSE, 컨테이너 내부 9100).
> 이 문서의 엔드포인트·필드·기본값은 그 인스턴스의 `/openapi.json`과 설치된 패키지 소스에서
> 직접 확인한 값입니다. 확인 방법은 [부록](#부록-이-문서의-사실을-직접-확인하는-법)에 있습니다.
> MCP는 LiteLLM에서 아직 `_experimental` 모듈이라 마이너 버전 사이에도 필드가 늘어납니다.

---

## 1. LiteLLM의 MCP는 무엇인가

MCP(Model Context Protocol)는 도구·데이터 소스를 모델에게 노출하는 개방형 프로토콜입니다.
MCP 이전에는 프레임워크마다 도구 호출 규약이 달라서 통합이 전부 일회성이었습니다.

**LiteLLM에 등록한다는 것은 도구를 클라이언트가 아니라 게이트웨이에 두는 것**입니다. 차이는
셋입니다.

| | 클라이언트마다 MCP 설정 | 게이트웨이에 등록 |
|---|---|---|
| 도구 추가 | 앱마다 반복 | 한 번, 모든 클라이언트가 상속 |
| 업스트림 자격증명 | 클라이언트마다 배포 | 게이트웨이에만 존재 |
| 호출 기록 | 앱이 남기면 남음 | 모델 호출과 같은 경로에 남음 |

### 노출되는 세 가지 표면

등록 한 번에 인터페이스가 세 개 생깁니다. 용도가 다르니 구분해서 쓰는 게 좋습니다.

| 표면 | 경로 | 쓰는 쪽 |
|---|---|---|
| MCP 프로토콜 | `POST /mcp/` (등록된 전체)<br>`POST /<server_name>/mcp` (개별 서버)<br>`POST /toolset/<toolset_name>/mcp` (툴셋) | Claude Code, Cursor 등 **MCP 클라이언트** |
| REST | `GET /mcp-rest/tools/list`<br>`POST /mcp-rest/tools/call` | MCP 클라이언트 없이 **직접 호출**하는 코드 |
| 관리 | `GET/POST/PUT /v1/mcp/server`, `GET /v1/mcp/server/health`, `GET /v1/mcp/tools` … | 등록·조회·헬스체크 자동화 |

인증은 셋 다 동일하게 `Authorization: Bearer <LITELLM_MASTER_KEY>` (또는 가상 키)입니다.

> [!WARNING]
> **`/mcp`가 아니라 `/mcp/` 입니다.** `POST /mcp`는 **307 리다이렉트**를 반환합니다.
> POST에서 리다이렉트를 따라가지 않는 클라이언트는 여기서 조용히 실패합니다.
> 슬래시를 붙여 `/mcp/`로 붙이세요.

---

## 2. MCP 서버의 기본 요건

등록하려는 서버가 만족해야 하는 조건입니다.

### 2.1 전송 방식 (transport)

v1.93.0이 받는 값은 `sse`, `http`, `stdio` 세 가지이고 **기본값은 `sse`** 입니다.

| transport | 형태 | 언제 |
|---|---|---|
| `sse` | HTTP Server-Sent Events | 원격 서버. 가장 널리 구현돼 있음 |
| `http` | Streamable HTTP | 최신 MCP 사양. 서버가 지원하면 우선 |
| `stdio` | 자식 프로세스의 stdin/stdout | **LiteLLM과 같은 컨테이너 안에서** 실행되는 서버 |

`stdio`는 게이트웨이가 프로세스를 직접 띄웁니다. 즉 그 실행 파일이 LiteLLM 컨테이너 안에
있어야 합니다. 별도 컨테이너로 띄우고 싶다면 stdio 서버를 SSE로 감싸는 방법을 씁니다.

```dockerfile
# stdio 전용 MCP 서버를 SSE로 노출하는 래퍼 (이 프로젝트의 docker/mcp/Dockerfile)
CMD ["mcp-proxy", "--port", "9100", "--host", "0.0.0.0", \
     "--pass-environment", "mcp-clickhouse"]
```

### 2.2 네트워크 도달성

기준은 **LiteLLM 컨테이너에서 보이는 주소**입니다. 호스트나 브라우저가 아닙니다.

- 같은 Compose 네트워크: `http://mcp-clickhouse:9100/sse` — 포트를 호스트에 공개할 필요 없음
- 외부 SaaS MCP: 공인 URL + 방화벽 아웃바운드 허용
- `localhost`는 LiteLLM 컨테이너 자신을 가리킵니다. 다른 컨테이너를 가리킬 때 흔한 실수입니다

### 2.3 인증 (auth_type)

`auth_type`에 들어갈 수 있는 값입니다. 업스트림이 요구하는 방식과 일치해야 합니다.

```
none · api_key · bearer_token · basic · authorization · token
oauth2 · oauth2_token_exchange · oauth_delegate · true_passthrough · aws_sigv4
```

- 정적 토큰류는 `credentials.auth_value`
- OAuth2는 `client_id` / `client_secret` / `scopes` / `authorization_url` / `token_url`,
  `oauth2_flow`는 `client_credentials` 또는 `authorization_code`
- 클라이언트가 자기 토큰을 들고 오게 하려면 요청 헤더 `x-mcp-auth` 를 씁니다

### 2.4 이름 규칙

서버 이름에 **`-` 를 넣을 수 없습니다.** LiteLLM이 도구 이름을 `<서버>-<도구>` 형태로
접두어 붙일 때 쓰는 구분자이기 때문입니다(`MCP_TOOL_PREFIX_SEPARATOR`, 환경 변수로 변경 가능).
`clickhouse_prod` 는 되고 `clickhouse-prod` 는 등록 시 400으로 거부됩니다.

### 2.5 권한은 업스트림 자격증명이 정합니다

게이트웨이는 도구를 노출할 뿐 권한을 만들지 않습니다. 데이터베이스 MCP라면 **읽기 전용 계정**을
따로 만들어 쓰세요. "쓰기 하지 마"라는 시스템 프롬프트는 접근 통제가 아닙니다.

---

## 3. 방법 A — `config.yaml`의 `mcp_servers`

파일이 곧 상태라서 Git으로 관리되고, DB 없이도 동작합니다. 이 프로젝트가 쓰는 방식입니다.

### 최소 설정

```yaml
mcp_servers:
  clickhouse:                              # 서버 이름 ('-' 불가)
    url: "http://mcp-clickhouse:9100/sse"
    transport: "sse"
```

### v1.93.0의 설정 로더가 읽는 키 (48개)

UI에서만 가능하다고 오해하기 쉬운데, YAML도 거의 전 범위를 받습니다. 아래는
`load_servers_from_config`가 실제로 읽는 키를 용도별로 묶은 것입니다.

| 분류 | 키 |
|---|---|
| 기본 | `url` · `transport` · `description` · `alias` · `instructions` · `spec_path` · `mcp_info` |
| 도구 제어 | `allowed_tools` · `disallowed_tools` · `allowed_params` |
| stdio | `command` · `args` · `env` · `env_vars` |
| 인증(공통) | `auth_type` · `auth_value` · `authentication_token` · `extra_headers` · `static_headers` |
| OAuth2 | `client_id` · `client_secret` · `scopes` · `authorization_url` · `token_url` · `registration_url` · `oauth2_flow` · `token_endpoint_auth_method` · `token_exchange_endpoint` · `token_exchange_profile` · `subject_token_type` · `audience` · `oauth_passthrough` · `delegate_auth_to_upstream` · `dcr_bridge` |
| AWS SigV4 | `aws_access_key_id` · `aws_secret_access_key` · `aws_session_token` · `aws_region_name` · `aws_role_name` · `aws_service_name` · `aws_session_name` |
| 접근·운영 | `access_groups` · `allow_all_keys` · `available_on_public_internet` · `timeout` · `max_concurrent_requests` · `allow_elicitation` · `allow_sampling` |

> [!NOTE]
> **YAML로 못 하는 것** — 위 목록에 없는 것들입니다. **팀 할당(`teams`)**, 도구 표시 이름·설명
> 오버라이드(`tool_name_to_display_name`, `tool_name_to_description`), BYOK 메타데이터, 그리고
> **`server_id` 직접 지정**(설정 서버의 id는 항상 파생됩니다). 이들이 필요하면 방법 B나 C를 쓰세요.

도구를 화이트리스트로 좁히고 타임아웃을 주는 실제 예:

```yaml
mcp_servers:
  clickhouse:
    url: "http://mcp-clickhouse:9100/sse"
    transport: "sse"
    description: "ClickHouse Cloud, read-only"
    allowed_tools: ["list_databases", "list_tables", "run_query"]
    timeout: 30
    access_groups: ["analytics"]
```

### stdio 예시

```yaml
mcp_servers:
  filesystem:
    transport: "stdio"
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/data"]
    env:
      NODE_ENV: "production"
```

### 별칭

```yaml
litellm_settings:
  mcp_aliases:
    ch: clickhouse        # 별칭 → 서버 이름
```

### `server_id`는 설정에서 파생됩니다

LiteLLM은 `(server_name, url, transport, auth_type, alias)`를 해시해 **재시작해도 안정적인**
`server_id`를 만듭니다. 가상 키 권한이 `server_id` 기준이기 때문입니다.

> [!WARNING]
> **URL을 바꾸면 `server_id`가 바뀝니다.** 포트나 호스트명만 고쳐도 새 id가 생성되고, 기존 키에
> 부여한 접근 권한이 그 서버를 가리키지 않게 됩니다. 주소를 바꿀 때는 권한도 같이 확인하세요.

### 적용

설정 파일은 **부팅 시에만** 읽힙니다.

```bash
docker compose up -d --no-deps litellm     # 설정 파일이 바뀐 경우
docker restart sais-litellm-1              # 마운트된 파일만 바뀐 경우
```

---

## 4. 방법 B — Admin UI

DB에 저장되므로 **재시작 없이 즉시 반영**됩니다. 팀 할당처럼 YAML에 없는 기능도 여기서 합니다.

### 사전 요건

```bash
DATABASE_URL=postgresql://...      # 필수
STORE_MODEL_IN_DB=True             # 필수
LITELLM_MASTER_KEY=sk-...          # UI 로그인
```

DB가 없으면 UI에 MCP 메뉴가 뜨더라도 저장이 되지 않습니다.

### 등록 절차

1. `http://<gateway>:4000/ui` 접속 → master key로 로그인
2. 좌측 내비게이션에서 **MCP Servers** 선택 *(메뉴 위치는 버전에 따라 다를 수 있습니다. 이
   화면이 호출하는 것은 §5의 `POST /v1/mcp/server`와 동일합니다)*
3. **Add New MCP Server** → 아래 값 입력

| 화면 항목 | 대응 필드 | 비고 |
|---|---|---|
| Server Name | `server_name` | `-` 불가 |
| Description | `description` | |
| Transport | `transport` | `sse` / `http` / `stdio` |
| URL | `url` | LiteLLM 컨테이너 기준 주소 |
| Auth Type + 값 | `auth_type`, `credentials` | 2.3 참고 |
| Allowed Tools | `allowed_tools` | 노출할 도구만 화이트리스트 |
| Access Groups / Teams | `mcp_access_groups`, `teams` | 키·팀 단위 접근 제어 |

4. 저장 후 목록에서 **health 상태**와 도구 개수를 확인

### 설정 파일과 UI를 함께 쓸 때

부팅 시 `mcp_servers`의 서버는 메모리에 올라가고 DB로 백필됩니다. **소스는 여전히 파일**이라,
UI에서 그 서버를 고쳐도 다음 재시작 때 파일 내용으로 돌아갑니다. 혼선을 줄이려면 서버별로
한쪽만 쓰세요 — 기반 인프라는 YAML, 실험·팀별 추가는 UI 식으로 나누는 편이 안전합니다.

---

## 5. 방법 C — 관리 API

UI가 하는 일을 그대로 하는 API입니다. CI나 테넌트 프로비저닝 자동화에 씁니다.

```bash
curl -X POST http://localhost:4000/v1/mcp/server \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "server_name": "clickhouse_prod",
        "description": "ClickHouse Cloud, read-only",
        "transport": "sse",
        "url": "http://mcp-clickhouse:9100/sse",
        "auth_type": "none",
        "allowed_tools": ["list_databases", "list_tables", "run_query"],
        "mcp_access_groups": ["analytics"]
      }'
```

| 동작 | 호출 |
|---|---|
| 목록 | `GET /v1/mcp/server` |
| 단건 조회 / 삭제 | `GET` / `DELETE /v1/mcp/server/{server_id}` |
| 수정 | `PUT /v1/mcp/server` |
| 헬스 | `GET /v1/mcp/server/health?server_ids=...` |
| 도구 목록 | `GET /v1/mcp/tools` |

---

## 6. 등록 확인 — 5단계

아래는 실제 실행 결과입니다. 순서대로 통과하면 등록이 끝난 것입니다.

**1. 서버가 잡혔는가**

```bash
curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://localhost:4000/v1/mcp/server
```
```json
{"server_id": "0e85df71b936e7d5744db094e2853597", "server_name": "clickhouse",
 "url": "http://mcp-clickhouse:9100/sse", "transport": "sse", "teams": []}
```

**2. 살아 있는가**

```bash
curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://localhost:4000/v1/mcp/server/health
```
```json
[{"server_id":"0e85df71b936e7d5744db094e2853597","status":"healthy"}]
```

**3. 도구가 보이는가**

```bash
curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://localhost:4000/mcp-rest/tools/list
```
```text
list_databases | List available ClickHouse databases     | mcp_info.server_id = 0e85df...
list_tables    | List tables in a database, with schema  | mcp_info.server_id = 0e85df...
run_query      | Execute SQL (read-only)                 | mcp_info.server_id = 0e85df...
```

`server_id`, `mcp_server_name`, `toolset_name` 쿼리 파라미터로 좁힐 수 있습니다.

**4. MCP 프로토콜로 붙는가**

```bash
curl -s -X POST http://localhost:4000/mcp/ \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
       "params":{"protocolVersion":"2025-06-18","capabilities":{},
                 "clientInfo":{"name":"probe","version":"1"}}}'
```
```text
event: message
data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18", ...}}
```

개별 서버만 붙이려면 `POST /clickhouse/mcp` 를 씁니다.

**5. 실제로 실행되는가**

```bash
curl -s -X POST http://localhost:4000/mcp-rest/tools/call \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"list_databases","arguments":{},
       "server_id":"0e85df71b936e7d5744db094e2853597"}'
```

응답은 `{"content":[{"type":"text","text":"..."}], "_meta":null}` 형태입니다. 서버가 하나뿐이면
`server_id`는 생략해도 되지만, 여러 서버에 같은 이름의 도구가 있으면 반드시 지정해야 합니다.

---

## 7. 등록한 도구를 모델에 물리는 두 가지 방식

등록은 도구를 **사용 가능하게** 만들 뿐, 모델이 자동으로 쓰지는 않습니다. 선택지는 둘입니다.

**(a) 클라이언트가 MCP 클라이언트로 붙는다** — Claude Code, Cursor 등은 `/mcp/`를 그대로 씁니다.
게이트웨이 설정 외에 할 일이 없지만, 도구를 쓸지 말지는 클라이언트가 정합니다.

**(b) 게이트웨이가 도구를 주입하고 루프까지 돌린다** — 채팅 요청에 `tools`를 끼워 넣고, 모델이
`tool_calls`로 답하면 게이트웨이가 `/mcp-rest/tools/call`로 실행한 뒤 결과를 붙여 다시 물어봅니다.
MCP를 전혀 모르는 클라이언트(LibreChat 등)도 도구 기반 답변을 받게 됩니다. 이 프로젝트가 쓰는
방식이고 구현은 `docker/litellm_callbacks.py`의 `UnifiedRouter`에 있습니다.

(b)를 직접 구현한다면 반드시 지킬 것 두 가지:

- **홉 상한을 두고, 소진 시 "지금까지의 결과로 답하라"고 한 번 더 요청**하세요. 유능한 모델은
  항상 다음 쿼리를 하나 더 찾아냅니다.
- **실행하지 못한 `tool_calls`를 클라이언트에게 되돌려주지 마세요.** MCP를 모르는 클라이언트는
  그걸 자기가 실행하려다 `Tool "<이름>" not found`를 띄우고, 게이트웨이 쪽 문제가 도구 누락처럼
  보이게 됩니다.

---

## 8. 운영 체크리스트

- [ ] 업스트림 계정이 **최소 권한**인가 (DB라면 읽기 전용)
- [ ] MCP 포트를 호스트에 공개하지 않았는가 (컨테이너 내부 통신이면 불필요)
- [ ] `allowed_tools`로 필요한 도구만 노출했는가 (UI/API 경로)
- [ ] 도구 스키마를 감당 못 하는 모델에 주입하고 있지 않은가 — 작은 모델은 함수 호출이 불안정해서,
      도구가 필요한 요청만 강한 모델로 라우팅하는 편이 낫습니다
- [ ] 도구 호출이 **트레이스에 남는가** — 남지 않으면 무엇을 조회했는지 사후에 알 수 없습니다
- [ ] `server_id` 기반 키 권한이 URL 변경 뒤에도 유효한가

---

## 9. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `/mcp` 호출이 307만 반환 | 트레일링 슬래시 누락 | `/mcp/` 로 호출 |
| `/mcp` 404 | `mcp_servers` 없이 렌더된 설정 | 설정에 블록 추가 후 재시작, `grep -A5 mcp_servers` 로 확인 |
| 등록 시 400 `Server name cannot contain '-'` | 이름에 구분자 포함 | `_` 등으로 변경 |
| health `unhealthy` | 컨테이너에서 URL 도달 불가 | `docker exec litellm curl <url>` 로 확인. `localhost` 오용 주의 |
| 도구 목록이 비어 있음 | 업스트림이 stdio 전용인데 `sse`로 등록 | `mcp-proxy`로 감싸거나 `transport: stdio` |
| 도구 호출이 인증 오류 | `auth_type` 불일치 또는 자격증명 미설정 | 업스트림 요구 방식 확인, `x-mcp-auth` 검토 |
| 이름이 같은 도구가 섞임 | 서버 여러 개에 동일 도구명 | 호출 시 `server_id` 지정, `alias`로 접두어 부여 |
| UI에서 저장이 안 됨 | `STORE_MODEL_IN_DB` 미설정 또는 DB 없음 | 4장 사전 요건 확인 |
| UI 수정이 재시작 후 사라짐 | 그 서버의 소스가 `config.yaml` | 파일을 고치거나, 서버별로 한쪽 경로만 사용 |

---

## 부록: 이 문서의 사실을 직접 확인하는 법

버전이 올라가면 필드가 바뀝니다. 추측하지 말고 실행 중인 인스턴스에 물어보세요.

```bash
# 1. 버전과 MCP 관련 라우트 전체
curl -s http://localhost:4000/openapi.json \
  | python3 -c "import sys,json; s=json.load(sys.stdin); \
print(s['info']['version']); \
print('\n'.join(sorted(p for p in s['paths'] if 'mcp' in p.lower())))"

# 2. 등록 요청이 받는 필드와 enum
curl -s http://localhost:4000/openapi.json \
  | python3 -c "import sys,json; s=json.load(sys.stdin); \
print(json.dumps(s['components']['schemas']['NewMCPServerRequest']['properties'], indent=1))"

# 3. YAML 로더가 실제로 읽는 키 (설치된 소스 기준)
#    파일 전체를 grep하면 다른 함수의 키까지 섞입니다. 함수 범위로 잘라야 정확합니다.
docker exec -i <litellm-container> python - <<'PY'
import ast, re, glob
p = glob.glob('/app/.venv/lib/python3*/site-packages/litellm/proxy/'
              '_experimental/mcp_server/mcp_server_manager.py')[0]
src = open(p).read(); lines = src.splitlines()
for n in ast.walk(ast.parse(src)):
    if getattr(n, 'name', '') == 'load_servers_from_config':
        body = "\n".join(lines[n.lineno - 1:n.end_lineno])
        print(sorted(set(re.findall(r'server_config\.get\(\s*"([a-z_0-9]+)"', body))))
PY
```

관련 문서: [LiteLLM MCP 공식 문서](https://docs.litellm.ai/docs/mcp) ·
[MCP 사양](https://modelcontextprotocol.io)
