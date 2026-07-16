function spaces(count, out, i) {
  out = ""
  for (i = 0; i < count; i++) {
    out = out " "
  }
  return out
}

function indent(line) {
  match(line, /^ */)
  return RLENGTH
}

function blank_or_comment(line) {
  return line ~ /^[[:space:]]*($|#)/
}

function key_at(line, key, key_indent) {
  return line ~ ("^" spaces(key_indent) key ":[[:space:]]*(#.*)?$")
}

function block_end(start, block_indent, idx) {
  for (idx = start + 1; idx <= line_count; idx++) {
    if (blank_or_comment(lines[idx])) {
      continue
    }
    if (indent(lines[idx]) <= block_indent) {
      return idx
    }
  }
  return line_count + 1
}

function strip_yaml_scalar(value) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
  if (value ~ /^'.*'$/) {
    value = substr(value, 2, length(value) - 2)
    gsub(/''/, "'", value)
  } else if (value ~ /^".*"$/) {
    value = substr(value, 2, length(value) - 2)
  }
  return value
}

function add_url(url) {
  if (url == "" || seen[url]) {
    return
  }
  seen[url] = 1
  merged[++merged_count] = url
}

function quote_yaml(value) {
  gsub(/'/, "''", value)
  return "'" value "'"
}

BEGIN {
  while ((getline url < private_urls_file) > 0) {
    add_url(url)
  }
  close(private_urls_file)
}

{
  lines[++line_count] = $0
}

END {
  for (idx = 1; idx <= line_count; idx++) {
    if (key_at(lines[idx], "networks", 0)) {
      networks_idx = idx
      break
    }
  }
  if (!networks_idx) {
    print "could not find networks key" > "/dev/stderr"
    exit 1
  }

  networks_end = block_end(networks_idx, 0)
  for (idx = networks_idx + 1; idx < networks_end; idx++) {
    if (key_at(lines[idx], "base", 2)) {
      base_idx = idx
      break
    }
  }
  if (!base_idx) {
    print "could not find networks.base key" > "/dev/stderr"
    exit 1
  }

  base_end = block_end(base_idx, 2)
  for (idx = base_idx + 1; idx < base_end; idx++) {
    if (key_at(lines[idx], "rpcs", 4)) {
      rpcs_idx = idx
      break
    }
  }
  if (!rpcs_idx) {
    print "could not find networks.base.rpcs key" > "/dev/stderr"
    exit 1
  }

  rpcs_end = block_end(rpcs_idx, 4)
  for (idx = rpcs_idx + 1; idx < rpcs_end; idx++) {
    if (lines[idx] ~ /^[[:space:]]*-[[:space:]]*/) {
      value = lines[idx]
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      add_url(strip_yaml_scalar(value))
    }
  }

  for (idx = 1; idx <= rpcs_idx; idx++) {
    print lines[idx]
  }
  for (idx = 1; idx <= merged_count; idx++) {
    print "      - " quote_yaml(merged[idx])
  }
  for (idx = rpcs_end; idx <= line_count; idx++) {
    print lines[idx]
  }
}
