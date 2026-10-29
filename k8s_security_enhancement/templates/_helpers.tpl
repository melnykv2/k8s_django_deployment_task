{{/* Namespace of all application resources */}}
{{- define "app.namespace" -}}
{{ .Values.namespace.name }}
{{- end }}
