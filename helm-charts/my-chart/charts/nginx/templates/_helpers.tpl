{{- define "nginx.name" -}}
{{- .Release.Name }}-nginx
{{- end }}

{{- define "nginx.labels" -}}
app: {{ include "nginx.name" . }}
{{- end }}
