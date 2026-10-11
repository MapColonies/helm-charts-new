package lib.workload

# Shared by the workload rules (CPU ratio and mclabels).

# evaluate is true when a rule should check this review. CREATE and audit (no
# operation, no old object) always evaluate. An UPDATE evaluates only when it
# changes the Pod template, i.e. creates a new revision, so scaling a grandfathered
# workload or patching its own metadata is never blocked.
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

# exempt is true when the workload is in the Constraint's exemption list, or its
# own metadata (not the Pod template) carries a non-empty <annotation>.
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
