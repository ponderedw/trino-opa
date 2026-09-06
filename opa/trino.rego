package trino

import future.keywords.if
import future.keywords.in

# Deny everything by default — explicit grants only.
default allow := false

# ──────────────────────────────────────────────────────────────────────────────
# Admin
# ──────────────────────────────────────────────────────────────────────────────

allow if {
	input.context.identity.user == "admin"
}

# ──────────────────────────────────────────────────────────────────────────────
# Shared helpers
# ──────────────────────────────────────────────────────────────────────────────

_read_ops := {
	"ExecuteQuery",
	"AccessCatalog",
	"FilterCatalogs",
	"ShowSchemas", "FilterSchemas",
	"ShowTables", "FilterTables",
	"ShowColumns", "FilterColumns",
	"SelectFromColumns",
	"ExecuteFunction", "FilterFunctions",
	"ExecuteProcedure",
}

# ──────────────────────────────────────────────────────────────────────────────
# read_only_user — school staff, read access to SIS and assessment data
# ──────────────────────────────────────────────────────────────────────────────

_read_only_catalogs := {"powerschool", "illuminate"}

allow if {
	input.context.identity.user == "read_only_user"
	input.action.operation in _read_ops
	input.action.resource.table.catalogName in _read_only_catalogs
}

# Allow catalog/schema browsing before a table resource is resolved.
allow if {
	input.context.identity.user == "read_only_user"
	input.action.operation in {"ExecuteQuery", "AccessCatalog", "FilterCatalogs", "ShowSchemas", "FilterSchemas"}
	not input.action.resource.table
}

# ──────────────────────────────────────────────────────────────────────────────
# bi_developer — reads source + BI catalogs, writes to dev_ schemas in bi_prod
# ──────────────────────────────────────────────────────────────────────────────

_bi_developers := {"alice", "bob"}

_bi_read_catalogs := {"powerschool", "illuminate", "bi_prod"}

allow if {
	input.context.identity.user in _bi_developers
	input.action.operation in _read_ops
	input.action.resource.table.catalogName in _bi_read_catalogs
}

allow if {
	input.context.identity.user in _bi_developers
	input.action.operation in {"ExecuteQuery", "AccessCatalog", "FilterCatalogs", "ShowSchemas", "FilterSchemas"}
	not input.action.resource.table
}

allow if {
	input.context.identity.user in _bi_developers
	input.action.operation in {"ShowTables", "FilterTables"}
	input.action.resource.schema.catalogName in _bi_read_catalogs
}

# Full write access to dev_ prefixed schemas in bi_prod (building BI models).
allow if {
	input.context.identity.user in _bi_developers
	input.action.resource.table.catalogName == "bi_prod"
	startswith(input.action.resource.table.schemaName, "dev_")
}

allow if {
	input.context.identity.user in _bi_developers
	input.action.resource.schema.catalogName == "bi_prod"
	startswith(input.action.resource.schema.schemaName, "dev_")
}

# ──────────────────────────────────────────────────────────────────────────────
# dbt_developer — reads source catalogs, writes to dev_ schemas in sandbox
# ──────────────────────────────────────────────────────────────────────────────

_dbt_developers := {"charlie", "dave"}

_dbt_read_catalogs := {"powerschool", "illuminate"}

allow if {
	input.context.identity.user in _dbt_developers
	input.action.operation in _read_ops
	input.action.resource.table.catalogName in _dbt_read_catalogs
}

allow if {
	input.context.identity.user in _dbt_developers
	input.action.operation in {"ExecuteQuery", "AccessCatalog", "FilterCatalogs", "ShowSchemas", "FilterSchemas"}
	not input.action.resource.table
}

allow if {
	input.context.identity.user in _dbt_developers
	input.action.operation in {"ShowTables", "FilterTables"}
	input.action.resource.schema.catalogName in _dbt_read_catalogs
}

# Full write access to dev_ prefixed schemas in sandbox (building dbt models).
allow if {
	input.context.identity.user in _dbt_developers
	input.action.resource.table.catalogName == "sandbox"
	startswith(input.action.resource.table.schemaName, "dev_")
}

allow if {
	input.context.identity.user in _dbt_developers
	input.action.resource.schema.catalogName == "sandbox"
	startswith(input.action.resource.schema.schemaName, "dev_")
}

# ──────────────────────────────────────────────────────────────────────────────
# Batched filter rules (opa.policy.batched-uri)
# ──────────────────────────────────────────────────────────────────────────────

batch contains i if {
	input.context.identity.user == "admin"
	input.action.filterResources[i]
}

# read_only_user batch
batch contains i if {
	input.context.identity.user == "read_only_user"
	resource := input.action.filterResources[i]
	resource.catalog.name in _read_only_catalogs
}

batch contains i if {
	input.context.identity.user == "read_only_user"
	resource := input.action.filterResources[i]
	resource.schema.catalogName in _read_only_catalogs
}

batch contains i if {
	input.context.identity.user == "read_only_user"
	resource := input.action.filterResources[i]
	resource.table.catalogName in _read_only_catalogs
}

# bi_developer batch
batch contains i if {
	input.context.identity.user in _bi_developers
	resource := input.action.filterResources[i]
	resource.catalog.name in _bi_read_catalogs
}

batch contains i if {
	input.context.identity.user in _bi_developers
	resource := input.action.filterResources[i]
	resource.schema.catalogName in _bi_read_catalogs
}

batch contains i if {
	input.context.identity.user in _bi_developers
	resource := input.action.filterResources[i]
	resource.table.catalogName in _bi_read_catalogs
}

batch contains i if {
	input.context.identity.user in _bi_developers
	resource := input.action.filterResources[i]
	resource.schema.catalogName == "bi_prod"
	startswith(resource.schema.schemaName, "dev_")
}

batch contains i if {
	input.context.identity.user in _bi_developers
	resource := input.action.filterResources[i]
	resource.table.catalogName == "bi_prod"
	startswith(resource.table.schemaName, "dev_")
}

# dbt_developer batch
batch contains i if {
	input.context.identity.user in _dbt_developers
	resource := input.action.filterResources[i]
	resource.catalog.name in _dbt_read_catalogs
}

batch contains i if {
	input.context.identity.user in _dbt_developers
	resource := input.action.filterResources[i]
	resource.schema.catalogName in _dbt_read_catalogs
}

batch contains i if {
	input.context.identity.user in _dbt_developers
	resource := input.action.filterResources[i]
	resource.table.catalogName in _dbt_read_catalogs
}

batch contains i if {
	input.context.identity.user in _dbt_developers
	resource := input.action.filterResources[i]
	resource.schema.catalogName == "sandbox"
	startswith(resource.schema.schemaName, "dev_")
}

batch contains i if {
	input.context.identity.user in _dbt_developers
	resource := input.action.filterResources[i]
	resource.table.catalogName == "sandbox"
	startswith(resource.table.schemaName, "dev_")
}
