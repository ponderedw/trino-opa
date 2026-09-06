package trino

import future.keywords.if
import future.keywords.in

# Deny everything by default — explicit grants only.
default allow := false

# ──────────────────────────────────────────────────────────────────────────────
# Roles
# ──────────────────────────────────────────────────────────────────────────────

# Admin has unrestricted access to everything.
allow if {
	input.context.identity.user == "admin"
}

# ──────────────────────────────────────────────────────────────────────────────
# Read-only user
# ──────────────────────────────────────────────────────────────────────────────

_read_only_catalogs := {
	"analytics_prod",
	"analytics_stage",
	"reporting",
}

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

# Allow read operations on permitted catalogs.
allow if {
	input.context.identity.user == "read_only_user"
	input.action.operation in _read_ops
	input.action.resource.table.catalogName in _read_only_catalogs
}

# Allow catalog/schema browsing when no table resource is attached yet.
allow if {
	input.context.identity.user == "read_only_user"
	input.action.operation in {"ExecuteQuery", "AccessCatalog", "FilterCatalogs", "ShowSchemas", "FilterSchemas"}
	not input.action.resource.table
}

# ──────────────────────────────────────────────────────────────────────────────
# Analyst users — read access to BI catalogs, write in dev_ sandboxes
# ──────────────────────────────────────────────────────────────────────────────

_analyst_users := {"alice", "bob", "charlie"}

_analyst_catalogs := {"bi_prod", "sandbox"}

_write_ops := {
	"CreateSchema", "AlterSchema", "DropSchema",
	"CreateTable", "AlterTable", "DropTable",
	"InsertIntoTable", "DeleteFromTable", "TruncateTable",
	"CreateView", "DropView",
	"CreateMaterializedView", "DropMaterializedView",
}

# Read access to all analyst catalogs.
allow if {
	input.context.identity.user in _analyst_users
	input.action.operation in _read_ops
	input.action.resource.table.catalogName in _analyst_catalogs
}

# Catalog/schema browsing for analysts.
allow if {
	input.context.identity.user in _analyst_users
	input.action.operation in {"ExecuteQuery", "AccessCatalog", "FilterCatalogs", "ShowSchemas", "FilterSchemas"}
	not input.action.resource.table
}

# ShowTables sends a schema resource, not a table resource.
allow if {
	input.context.identity.user in _analyst_users
	input.action.operation in {"ShowTables", "FilterTables"}
	input.action.resource.schema.catalogName in _analyst_catalogs
}

# Full write access inside any schema whose name starts with "dev_" in the sandbox catalog.
allow if {
	input.context.identity.user in _analyst_users
	input.action.resource.table.catalogName == "sandbox"
	startswith(input.action.resource.table.schemaName, "dev_")
}

allow if {
	input.context.identity.user in _analyst_users
	input.action.resource.schema.catalogName == "sandbox"
	startswith(input.action.resource.schema.schemaName, "dev_")
}

# ──────────────────────────────────────────────────────────────────────────────
# Batched filter rules (opa.policy.batched-uri)
#
# Trino calls the batch endpoint when it needs to filter a list of resources
# (e.g. listing catalogs, schemas, or tables) in a single OPA call.
# Each rule adds the *index* of an allowed resource to the `batch` set.
# ──────────────────────────────────────────────────────────────────────────────

batch contains i if {
	input.context.identity.user == "admin"
	input.action.filterResources[i]
}

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
	input.context.identity.user in _analyst_users
	resource := input.action.filterResources[i]
	resource.catalog.name in _analyst_catalogs
}

batch contains i if {
	input.context.identity.user in _analyst_users
	resource := input.action.filterResources[i]
	resource.schema.catalogName in _analyst_catalogs
}

batch contains i if {
	input.context.identity.user in _analyst_users
	resource := input.action.filterResources[i]
	resource.table.catalogName in _analyst_catalogs
}

# Allow analysts to filter dev_ sandbox schemas/tables.
batch contains i if {
	input.context.identity.user in _analyst_users
	resource := input.action.filterResources[i]
	resource.table.catalogName == "sandbox"
	startswith(resource.table.schemaName, "dev_")
}

batch contains i if {
	input.context.identity.user in _analyst_users
	resource := input.action.filterResources[i]
	resource.schema.catalogName == "sandbox"
	startswith(resource.schema.schemaName, "dev_")
}
