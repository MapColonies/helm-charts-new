package k8sworkloadcpuratio

# Every container and init container of a workload's Pod template must set a CPU
# request and a CPU limit of exactly 4x that request. Ephemeral containers and
# memory are not checked. One violation per offending container.

violation[{"msg": msg}] {
	container := pod_containers[_]
	not compliant(container)
	msg := sprintf("%v %v/%v container %q: CPU limit must be exactly 4x the CPU request (%v). To exempt this workload, add it to the site-values exemption list or set the mapcolonies.io/exempt-cpu-ratio annotation to a reason.", [input.review.object.kind, namespace, input.review.object.metadata.name, container.name, details(container)])
}

pod_containers[c] {
	c := input.review.object.spec.template.spec.containers[_]
}

pod_containers[c] {
	c := input.review.object.spec.template.spec.initContainers[_]
}

namespace = ns {
	ns := input.review.object.metadata.namespace
	ns != ""
} else = ns {
	ns := object.get(input.review, "namespace", "")
}

cpu(container, field) = q {
	q := container.resources[field].cpu
}

compliant(container) {
	request := nanocores(cpu(container, "requests"))
	limit := nanocores(cpu(container, "limits"))
	request > 0
	limit == 4 * request
}

details(container) = s {
	notes := [sprintf("; %q is not a valid CPU quantity", [sprintf("%v", [q])]) |
		field := ["requests", "limits"][_]
		q := cpu(container, field)
		not nanocores(q)
	]
	s := sprintf("request: %v, limit: %v, expected limit: %v%v", [shown(container, "requests"), shown(container, "limits"), expected_limit(container), concat("", notes)])
}

shown(container, field) = s {
	s := sprintf("%v", [cpu(container, field)])
} else = "none"

expected_limit(container) = s {
	s := format_nanocores(4 * nanocores(cpu(container, "requests")))
} else = "4x the request"

# nanocores converts a CPU quantity (a YAML number or a Kubernetes quantity
# string such as "500m", "62500u", "2" or "1e3") to an exact integer number of
# nanocores. Fractions below a nanocore round up, as Kubernetes does. Undefined
# when the value is not a quantity.
nanocores(q) = n {
	is_number(q)
	n := parse_quantity(sprintf("%v", [q]))
}

nanocores(q) = n {
	is_string(q)
	n := parse_quantity(q)
}

parse_quantity(s) = n {
	[_, int_part, frac_part, suffix] := regex.find_all_string_submatch_n(`^([0-9]*)(?:\.([0-9]*))?(n|u|m|k|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei|[eE][+-]?[0-9]+)?$`, s, 1)[0]
	count(concat("", [int_part, frac_part])) > 0
	[power, multiplier] := suffix_scale(suffix)
	n := scale_digits(concat("", [int_part, frac_part]), (9 + power) - count(frac_part)) * multiplier
}

decimal_suffixes := {"n": -9, "u": -6, "m": -3, "": 0, "k": 3, "M": 6, "G": 9, "T": 12, "P": 15, "E": 18}

binary_suffixes := {"Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776, "Pi": 1125899906842624, "Ei": 1152921504606846976}

suffix_scale(suffix) = [power, 1] {
	power := decimal_suffixes[suffix]
}

suffix_scale(suffix) = [0, multiplier] {
	multiplier := binary_suffixes[suffix]
}

suffix_scale(suffix) = [power, 1] {
	regex.match(`^[eE]`, suffix)
	power := to_number(substring(suffix, 1, -1))
}

zeros := "0000000000000000000000000000000000000000000000000000000000000000"

# scale_digits returns the integer value of digits * 10^shift, rounded up.
scale_digits(digits, shift) = n {
	shift >= 0
	shift <= count(zeros)
	n := digits_value(concat("", [digits, substring(zeros, 0, shift)]))
}

scale_digits(digits, shift) = n {
	shift < 0
	keep := max([count(digits) + shift, 0])
	whole := digits_value(substring(digits, 0, keep))
	n := whole + rounding(substring(digits, keep, -1))
}

rounding(dropped) = 1 {
	trim_left(dropped, "0") != ""
} else = 0

digits_value(digits) = n {
	trimmed := trim_left(digits, "0")
	trimmed != ""
	n := to_number(trimmed)
} else = 0

format_nanocores(n) = s {
	n % 1000000000 == 0
	s := format_int(n / 1000000000, 10)
} else = s {
	n % 1000000 == 0
	s := sprintf("%vm", [format_int(n / 1000000, 10)])
} else = s {
	n % 1000 == 0
	s := sprintf("%vu", [format_int(n / 1000, 10)])
} else = s {
	s := sprintf("%vn", [format_int(n, 10)])
}
