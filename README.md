# OpenTelemetry Java agent 3.0 preview on Coralogix

A small Spring JDBC app, instrumented with the OpenTelemetry Java agent **2.32.0** (the 3.0 release candidate), sending traces, metrics, and logs to Coralogix. It compares three installs against the same Postgres database:

| Mode     | Command              | Preview | Export                         |
| -------- | -------------------- | ------- | ------------------------------ |
| `legacy` | `./deploy.sh legacy` | off     | Direct to `ingress.$CX_DOMAIN` |
| `v3`     | `./deploy.sh v3`     | on      | Direct to `ingress.$CX_DOMAIN` |
| `chart`  | `./deploy.sh chart`  | on      | Coralogix via the chart agent  |

The chart app has no Coralogix key. It sends OTLP to the `otel-integration` agent in the cluster, and that agent exports to Coralogix. `./deploy.sh` with no arguments runs every mode in one kind cluster and one namespace, `otel-java-v3`. The chart release is installed in that same namespace. `legacy`, `v3`, or `chart` deploys a single mode.

Agent 2.32.0 keeps today's semantic conventions unless `OTEL_INSTRUMENTATION_COMMON_V3_PREVIEW=true`. That flag is what 3.0 will make the default. HTTP conventions are already stable in 2.32 either way. Database conventions, pool metrics, and SLF4J key-value capture change under the preview.

## Deploy

Requirements: Docker, kind, kubectl, Helm, Maven, Java 21.

```bash
export CX_PRIVATE_KEY='<send-your-data key>'
export CX_DOMAIN='us2.coralogix.com'          # optional, this is the default
export CX_CLUSTER_NAME='otel-java-v3'         # optional
export CX_APP_NAME='otel-java-agent-3'        # optional, standalone application name

./deploy.sh                 # all three, namespace otel-java-v3
./deploy.sh legacy
./deploy.sh v3
./deploy.sh chart
./deploy.sh status
./deploy.sh down
```

`REBUILD=1 ./deploy.sh v3` rebuilds the image. The script stores its kubeconfig in `.kube/config` in this repo and does not switch your default kubectl context. The API key is stored only as a Kubernetes secret.

The chart install uses `otel-integration` **0.0.352** from `coralogix-charts-virtual`. It sets `global.domain` and `global.clusterName` and leaves every other value at that chart's default, including Java auto-instrumentation (disabled). `us2.coralogix.com` is the domain that accepted this key. `coralogix.us` returned Unauthenticated from the chart's exporter.

### What each deploy starts

Shared pieces are a kind cluster, Postgres 16, and the orders image. The app creates schema `shop`, then serves insert, select, update, and a failing query against `shop.missing_table`. A curl loop keeps traffic moving. Order SKUs are `legacy`, `preview`, and `chart` so the three copies are easy to tell apart.

| Install       | Service           | Subsystem    | Preview |
| ------------- | ----------------- | ------------ | ------- |
| Direct legacy | `orders-legacy`   | `legacy`     | `false` |
| Direct v3     | `orders-v3`       | `v3-preview` | `true`  |
| Chart only    | `orders-v3-chart` | `v3-chart`   | `true`  |

The Service column is also `OTEL_SERVICE_NAME`. The chart rewrites Coralogix application and subsystem from Kubernetes metadata before export. The chart copy shows up as application `otel-java-v3` (the namespace) and subsystem `orders-v3-chart` (the deployment), not as `otel-java-agent-3` / `v3-chart`.

Look up the team that owns the send-your-data key. This run was checked on the `dmb-sm` profile:

```bash
cx spans "filter \$l.serviceName == 'orders-v3'" --start now-1h -p dmb-sm
cx logs "filter \$l.subsystemname == 'v3-preview' && \$d.body == 'created order'" --start now-1h -p dmb-sm
cx metrics query 'sum by (service_name, db_system_name, db_namespace, db_query_summary) (db_client_operation_duration_s_count{service_name=~"orders-v3|orders-v3-chart"})' -p dmb-sm
```

Span search by `serviceName` can lag the log and metric indexes. `wildfind` on a trace id from a `created order` log finds the spans sooner.

## Findings

Verified with agent 2.32.0, JDBC to Postgres database `orders` schema `shop`, on 6 Oct 2026.

### Direct legacy vs direct v3

Both copies export to the same ingress with the same key. Coralogix stores the attributes it is given. It does not alias the new database keys back to the old ones.

Database spans from the legacy deploy still carry `db.system=postgresql`, `db.name=orders`, `db.statement`, `db.operation`, `db.sql.table`, `db.user`, `db.connection_string`, and `server.port`. The span name is already `INSERT shop.orders`.

The same call with the preview uses:

- `db.system.name=postgresql`
- `db.namespace=orders|shop` (database and schema, not the old `db.name`)
- `db.query.text` for the statement, with literals already replaced by `?`
- `db.query.summary` such as `INSERT shop.orders`
- `server.address=postgres`

`db.system`, `db.name`, `db.statement`, `db.operation`, `db.sql.table`, `db.user`, `db.connection_string`, and `server.port` are absent. `db.operation.name` and `db.collection.name` are also absent on these JDBC spans. The operation and table are in the span name and in `db.query.summary`. The preview also emits an extra client span named `orders|shop` whose `db.query.text` is empty.

HTTP server spans match on both deploys (`http.request.method`, `http.response.status_code`, `http.route`, `url.path`, `url.scheme`). The preview does not add `http.method`.

Pool metrics rename and change unit. Legacy emits `db.client.connections.*` with wait and use time in milliseconds. The preview emits `db.client.connection.*` (singular) with those times in seconds, and adds `db.client.operation.duration` in seconds. The failed query is labeled `db.query.summary=SELECT shop.missing_table` and `error.type=42P01`. The legacy deploy does not emit `db.client.operation.duration`.

SLF4J key-values are captured only under the preview. `created order` on `orders-v3` has log attributes `order.id` and `order.sku`. The same line on `orders-legacy` has an empty attribute map.

### Chart path

`orders-v3-chart` uses the preview and talks only to the agent from `otel-integration` 0.0.352 at `http://$(HOST_IP):4317`. That chart version delivered the spans, logs, and metrics to Coralogix.

Exported database spans still have only the new names (`db.system.name`, `db.namespace`, `db.query.text`, `db.query.summary`). The chart does not copy those onto `db.system` or `db.statement` on the span it forwards.

It does copy `http.request.method` to `http.method` on the HTTP span, so a chart-routed `POST /orders` span carries both. The direct v3 span does not.

Database span metrics produced by the chart (`db_calls_total`, `db_duration_ms`) do get `db.system=postgresql`, because `transform/db` copies `db.system.name` onto `db.system` only in that side pipeline. The agent's own `db.client.operation.duration` series is not rewritten and still has `db.system.name` only. General `calls_total` series are labeled by the new span names, including `orders|shop`.

SQL redaction in the chart (`redaction/spanname`) scrubs `db.statement` and `db.query`. It does not list `db.query.text`. Statements in this demo were already parameterized by the agent.

Span-metric dimensions already include `db.namespace`, `db.operation.name`, `db.collection.name`, and `db.system`. They do not include `db.system.name` or `db.query.summary`. On these JDBC spans, `db.operation.name` and `db.collection.name` were empty, so those dimensions did not group the preview traffic.

The chart's Java auto-instrumentation image is `autoinstrumentation-java:2.31.1`, which is older than this preview and is disabled by default. The collector does not need a change for the spans to arrive. Features that still read `db.system`, `db.statement`, or `db.name` will miss them.

## Recommendations

Update the backend and the Helm chart. A chart-only change does not cover agents that export directly, which is the normal Java agent install and the first two modes here.

### Backend

Accept the new database attributes, and keep reading the old ones while both are still in production.

- System: `db.system.name`, then `db.system`. Postgres stayed `postgresql`. Other systems change the value too. SQL Server becomes `microsoft.sql_server`.
- Identity: `db.namespace`, then `db.name`. These are not the same value. Here `db.name` was `orders` and `db.namespace` was `orders|shop`.
- Query text: `db.query.text`, then `db.statement`. The short form is `db.query.summary`, not `db.sql.table`.
- Do not require `db.operation.name` or `db.collection.name`. Agent 2.32.0 left them off the JDBC span and put the operation in the span name and `db.query.summary`.
- Treat the extra `orders|shop` span, with empty `db.query.text`, as its own operation. It shows up in `calls_total`.
- Pool and operation metrics changed name and unit. `db.client.connections.*` in milliseconds becomes `db.client.connection.*` in seconds, and the preview adds `db.client.operation.duration` in seconds. A millisecond threshold pointed at the new series is wrong by 1000x.

### Helm chart

The default chart already backfills `http.method` from `http.request.method` on exported spans. Do the database equivalent only where a real rename is safe, and teach the pieces that still assume the old keys.

- Add `db.query.text` to the SQL sanitizer next to `db.statement` and `db.query`, and the v3 attribute for the other database sanitizers. The preview statement is not scrubbed today.
- Add `db.system.name` and `db.query.summary` as span-metric dimensions beside `db.system`, `db.namespace`, `db.operation.name`, and `db.collection.name`.
- Keep `db.namespace` as its own field. Copying it into `db.name` would replace `orders` with `orders|shop`.
- Leave the `db.system.name` to `db.system` copy on the database span-metrics path. That path already works. Do not assume the same copy happened on the exported span. It does not.
- Bump `autoinstrumentation-java` off 2.31.1 only after queries, dashboards, and this chart accept the new names. 3.0 makes the preview the default, so that image bump is what turns it on for chart users.
