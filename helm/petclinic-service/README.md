# petclinic-service

One Helm chart for all eight Spring Petclinic microservices. It names no service
and no environment: the eight services and two environments exist only as
combinations of values files, which is what keeps a fix to the probe shape or
the securityContext from having to be made eight times.

```bash
helm upgrade --install customers-service helm/petclinic-service/ \
  -n petclinic-dev \
  -f helm-values/customers-service.yaml \
  -f helm-values/dev.yaml
```

Both `-f` flags are required. The chart's own `values.yaml` leaves `image.registry`
and `image.name` empty on purpose, so a render missing one of them still succeeds
— it just builds the image string from whatever arrived, and the result is valid
YAML that applies cleanly and then fails to pull:

| Files passed | Rendered `image:` |
|--------------|-------------------|
| neither | `"/:"` |
| env only | `"<registry>/:"` |
| service only | `"/<service>:<tag>"` |

`scripts/validate-helm.sh` always passes both.

## The values hierarchy

Helm merges maps deeply and replaces scalars and lists wholesale, last file wins:

| Order | File | Knows about |
|-------|------|-------------|
| 1 | `helm/petclinic-service/values.yaml` | neither service nor environment |
| 2 | `helm-values/{service}.yaml` | the service: port, image name, profiles, init containers |
| 3 | `helm-values/{env}.yaml` | the environment: registry, replica count, database endpoint |

The split is worth keeping. A service file that named an environment could not
be reused across them, and an env file that named a service would have to be
edited every time one was added.

**One inversion, and it is deliberate.** `autoscaling` and `podDisruptionBudget`
are set per *service* and overridden to off by `dev.yaml`. Whether a service
scales is a property of what the service is — a registry does not scale, a
dashboard nobody depends on does not need a PDB — so `prod.yaml` says nothing
about either. It is the last layer, and setting `autoscaling.enabled: true`
there would silently beat the `false` in `config-server.yaml`,
`discovery-server.yaml` and `admin-server.yaml`.

## Values reference

### Set per service (`helm-values/{service}.yaml`)

| Value | Purpose |
|-------|---------|
| `fullnameOverride` | The resource name. Set to the service name — the chart uses the release name verbatim rather than `chart-release` composition, so `api-gateway` stays `api-gateway` and Eureka, the Ingress backend and the Service all agree. |
| `component` | `app.kubernetes.io/component`. One of `server`, `service`, `gateway`, `admin`. |
| `image.name` | Image name only. The registry comes from the env file. |
| `image.tag` | `v1.0.0` today; CI replaces it with the commit SHA on every build. Never `latest`. |
| `service.port` | Also the container port and the probes' port — the three are never different for these services. |
| `springProfiles` | Rendered as `SPRING_PROFILES_ACTIVE`. |
| `env` | Extra static environment variables, `[{name, value}]`. |
| `secrets` | Secret-backed variables, `[{name, secretName, key}]`, rendered as `valueFrom.secretKeyRef`. The Secret is created by an ExternalSecret in `k8s/base/external-secrets/`; never inline a value. |
| `initContainers` | The startup-order waits. `config-server` gets none, `discovery-server` waits for config-server, everything else waits for both. |
| `configMap.data` | Non-secret configuration, consumed with `envFrom`. Rendered through `tpl`, so it may reference other values — see below. |
| `resources` | `100m/500m`, `128Mi/512Mi` for every service except `api-gateway` at `200m/1000m`. |
| `autoscaling` | `enabled` plus `minReplicas`/`maxReplicas`/`targetCPUUtilizationPercentage`. |
| `podDisruptionBudget` | `enabled` plus `minAvailable`. |

### Set per environment (`helm-values/{env}.yaml`)

| Value | dev | prod |
|-------|-----|------|
| `image.registry` | `…amazonaws.com/petclinic-dev` | `…amazonaws.com/petclinic-prod` |
| `replicaCount` | `1` (all services) | not set — per-service |
| `autoscaling.enabled` | `false` (all services) | not set — per-service |
| `podDisruptionBudget.enabled` | `false` (all services) | not set — per-service |
| `database.connectionString` | the dev RDS endpoint | **placeholder — see prod.yaml** |

**Why `prod.yaml` sets no replica count.** It cannot. Helm merges values; it does
not evaluate conditions, and `prod.yaml` is the last layer, so a `replicaCount: 2`
there would beat every per-service value — including the `replicaCount: 1` that
`admin-server` needs. Prod replica counts therefore live with the services, and
only the three without an HPA carry an explicit one:

| Service | prod | Where it comes from |
|---------|------|---------------------|
| `config-server` | 2 | `config-server.yaml` |
| `discovery-server` | 2 | `discovery-server.yaml` |
| `admin-server` | 1 | `admin-server.yaml` (also the chart default) |
| `api-gateway` | 2 | HPA floor — `replicas` omitted from the Deployment |
| `customers-service`, `visits-service`, `vets-service` | 2 | HPA floor |
| `genai-service` | 1 | HPA floor |

`dev.yaml` still sets `replicaCount: 1` for everything, from one shared file,
because "1" needs no exceptions.

### Chart defaults (`values.yaml`)

Everything not listed above: `podSecurityContext`, `containerSecurityContext`,
`probes`, `service.type`/`portName`, `imagePullPolicy`, `initContainerResources`,
`serviceAccount`, `nameOverride`, `imagePullSecrets`, `podAnnotations`,
`topologySpreadConstraints`.

`topologySpreadConstraints` is the one chart default that describes the cluster
rather than the service. It selects `app.kubernetes.io/part-of: petclinic` instead
of the release's own pods, so all eight services share a single spread budget —
with the per-service selector it would count one pod, always find a skew of zero,
and do nothing at one replica per service. `values.yaml` carries the reasoning,
including the measurement that prompted it.

## The `tpl` bridge between layers

`configMap.data` is rendered through Helm's `tpl`, which means a service file —
which cannot know an environment — can reference an environment value:

```yaml
# helm-values/customers-service.yaml
configMap:
  data:
    SPRING_DATASOURCE_URL: "{{ .Values.database.connectionString }}"
```

```yaml
# helm-values/dev.yaml
database:
  connectionString: jdbc:mysql://petclinic-dev-mysql.….rds.amazonaws.com:3306/petclinic
```

This is the only place the two layers meet, and it is deliberately narrow: the
alternative is either an environment value that names a service, or a service
value that names a host.

`templates/configmap.yaml` uses the presence of `SPRING_DATASOURCE_URL` as the
signal that a service is database-backed, and fails the render if
`database.connectionString` is empty. Without it the render produces
`SPRING_DATASOURCE_URL: ""`, which lints, applies and dry-runs cleanly, then
fails at pod start as a Hikari pool error naming a property rather than the file
that left it empty.

Note the constraint this puts on any future guard of the same kind: a `required`
call cannot live inline in a values string, because `toYaml` folds long scalars
across lines and a template action split mid-string does not parse.

## Probes

| Probe | Path | Period | Timeout | Failure threshold |
|-------|------|--------|---------|-------------------|
| startup | `/actuator/health` | 10s | 5s | 30 (up to 5 min) |
| readiness | `/actuator/health/readiness` | 10s | 5s | 3 |
| liveness | `/actuator/health/liveness` | 15s | 5s | 3 |

`config-server` overrides readiness and liveness back to `/actuator/health`. The
override is necessary, but not for the reason it looks like: the health groups
are fine, the endpoints are unreachable. Spring Cloud Config Server registers
`/{application}/{profile}` and `/{application}/{profile}/{label}`, which between
them match every two- and three-segment path — and `/actuator/health` and
`/actuator/health/readiness` are exactly those shapes. The config controller
answers first.

Measured through a port-forward on 2026-10-11:

| Path | Result |
|------|--------|
| `/actuator/health` | 200 — `{"name":"actuator","profiles":["health"],…}`, a config lookup |
| `/actuator/health/readiness` | 404 — parsed as label `readiness`, which is not a git label |
| `/actuator/health/liveness` | 404 — same |
| `/actuator` | 404 — one segment, matches no mapping |

The groups are not what is missing. The other seven services answer
`/actuator/health` with `{"groups":["liveness","readiness"],"status":"UP"}`, from
Spring Boot's Kubernetes auto-detection — which keys off `KUBERNETES_SERVICE_HOST`
and so applies to any pod, config-server included. `config-server` has no
`management` block of its own at all; nothing is misconfigured, the paths are
simply occupied.

Which leaves the part that is easy to miss: **config-server's probes are not
health checks.** All three land on a path the config controller owns, so what
they establish is that the HTTP server answers a config request — not that the
application is healthy. That is a weaker signal than the other seven services
get, and the override is still right: the alternative is a probe that 404s
forever and a pod that never becomes Ready. The override is in
`helm-values/config-server.yaml`, not here.

`initialDelaySeconds` is 0 on all three. The startupProbe already gates the
other two, so a liveness delay on top of it would only postpone the first
readiness success.

## Validating

```bash
./scripts/validate-helm.sh                      # all 16 (service, env) pairs
./scripts/validate-helm.sh --env dev
./scripts/validate-helm.sh --service vets-service
```

Lints, renders and client-side dry-runs each release. Note what the dry run does
not prove: `--dry-run=client` never contacts the API server, so it cannot tell
you a ServiceAccount, Secret or namespace is missing, or that the cluster is
reachable. A clean run means the manifests are well-formed and internally
consistent, not that they will deploy.

Rendering one release by hand:

```bash
helm template customers-service helm/petclinic-service/ \
  -n petclinic-dev \
  -f helm-values/customers-service.yaml \
  -f helm-values/dev.yaml
```
