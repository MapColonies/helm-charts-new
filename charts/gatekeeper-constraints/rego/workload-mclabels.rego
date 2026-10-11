package k8sworkloadmclabels

import data.lib.workload

# Reads Pod template labels only; workload metadata labels don't count.

required_labels := ["mapcolonies.io/owner", "mapcolonies.io/environment", "mapcolonies.io/part-of", "mapcolonies.io/component"]

owner_domains := {"vector", "raster", "3d", "app", "dem", "infra", "common", "automation"}

violation[{"msg": msg}] {
	workload.evaluate
	not workload.exempt("mapcolonies.io/exempt-mclabels")
	count(problems) > 0
	obj := input.review.object
	msg := sprintf("%v %v/%v: Pod template mclabels are missing or invalid: %v. To exempt this workload, add it to the site-values exemption list or set the mapcolonies.io/exempt-mclabels annotation to a reason.", [obj.kind, workload.namespace, obj.metadata.name, concat(", ", sort(problems))])
}

labels := object.get(input.review.object, ["spec", "template", "metadata", "labels"], {})

has_label(key) {
	_ = labels[key]
}

problems[sprintf("%v (missing)", [key])] {
	key := required_labels[_]
	not has_label(key)
}

problems[sprintf("%v (empty)", [key])] {
	key := required_labels[_]
	labels[key] == ""
}

problems[sprintf("mapcolonies.io/owner (\"%v\" is not one of %v)", [owner, concat(", ", sort(owner_domains))])] {
	owner := labels["mapcolonies.io/owner"]
	owner != ""
	not owner_domains[owner]
}

problems["mapcolonies.io/environment (\"undefined\" is not allowed)"] {
	labels["mapcolonies.io/environment"] == "undefined"
}
