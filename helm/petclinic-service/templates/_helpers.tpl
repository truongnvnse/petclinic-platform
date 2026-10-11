{{/*
_helpers.tpl — names, labels and selectors for the petclinic service chart.

Every template in this chart goes through these helpers, so the label set on a
Deployment, its pods, its Service and its HPA cannot drift apart. Anything that
builds its own label block is the thing that eventually disagrees with the rest.
*/}}

{{/*
Chart name and version, for the helm.sh/chart label.
*/}}
{{- define "petclinic-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The name every object in a release carries.

This is the RELEASE name, not the chart name. The chart is generic, so
`helm install api-gateway helm/petclinic-service/` has to produce a Service
called `api-gateway`: k8s/base/ingress/ingress.yaml targets `api-gateway:8080`,
and every init container polls `config-server:8888` and `discovery-server:8761`.
The usual chart convention of composing chart name + release name would give
`api-gateway-petclinic-service` and silently break all three.

helm-values/{service}.yaml sets fullnameOverride explicitly as well, so the
names survive a release installed under some other name.
*/}}
{{- define "petclinic-service.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Selector labels.

These land in Deployment.spec.selector.matchLabels, which is immutable once the
Deployment exists — so they are the two that can never need to change. Anything
an environment might want to relabel (component, version) belongs in the full
label set below, not here.
*/}}
{{- define "petclinic-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "petclinic-service.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Full label set — docs/technical-spec.md → "Standard Labels (All Resources)".
*/}}
{{- define "petclinic-service.labels" -}}
helm.sh/chart: {{ include "petclinic-service.chart" . }}
{{ include "petclinic-service.selectorLabels" . }}
app.kubernetes.io/part-of: petclinic
app.kubernetes.io/component: {{ .Values.component }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
ServiceAccount name: the release name unless serviceAccount.name overrides it.
*/}}
{{- define "petclinic-service.serviceAccountName" -}}
{{- default (include "petclinic-service.fullname" .) .Values.serviceAccount.name }}
{{- end }}

{{/*
Image reference. The registry comes from helm-values/{env}.yaml and the name
from helm-values/{service}.yaml — see the note in values.yaml for why they are
split rather than being one per-service URL.
*/}}
{{- define "petclinic-service.image" -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.name .Values.image.tag }}
{{- end }}
