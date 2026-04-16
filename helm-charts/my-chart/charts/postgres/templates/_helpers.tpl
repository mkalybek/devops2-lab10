{{- define "postgres.name" -}}
{{- .Release.Name }}-postgres
{{- end }}

{{- define "postgres.labels" -}}
app: {{ include "postgres.name" . }}
{{- end }}

{{- define "postgres.selectorLabels" -}}
app: {{ include "postgres.name" . }}
{{- end }}
