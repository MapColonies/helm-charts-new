package lib.workload

# Shared by the workload rules.

# Evaluate CREATE and audit always, UPDATE only when the Pod template changed.
evaluate {
	object.get(input.review, "operation", "") != "UPDATE"
}

evaluate {
	pod_template_changed
}

pod_template_changed {
	not is_object(input.review.oldObject)
}

pod_template_changed {
	object.get(input.review.oldObject, ["spec", "template"], null) != object.get(input.review.object, ["spec", "template"], null)
}

# Exempt via the exemption list or a non-empty <annotation> on the workload's own metadata.
exempt(annotation) {
	entry := input.parameters.exemptions[_]
	entry.namespace == namespace
	entry.kind == input.review.object.kind
	entry.name == input.review.object.metadata.name
}

exempt(annotation) {
	trim_space(object.get(input.review.object.metadata, ["annotations", annotation], "")) != ""
}

namespace = ns {
	ns := input.review.object.metadata.namespace
	ns != ""
} else = ns {
	ns := object.get(input.review, "namespace", "")
}
