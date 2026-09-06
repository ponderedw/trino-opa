package trino_test

import data.trino
import future.keywords.if
import future.keywords.in

# ── Admin ─────────────────────────────────────────────────────────────────────

test_admin_allows_any_operation if {
	trino.allow with input as {
		"context": {"identity": {"user": "admin"}},
		"action": {"operation": "DropTable", "resource": {}},
	}
}

test_admin_batch_allows_all if {
	allowed := trino.batch with input as {
		"context": {"identity": {"user": "admin"}},
		"action": {"filterResources": [
			{"catalog": {"name": "analytics_prod"}},
			{"catalog": {"name": "sandbox"}},
		]},
	}
	allowed == {0, 1}
}

# ── read_only_user ────────────────────────────────────────────────────────────

test_read_only_user_can_select if {
	trino.allow with input as {
		"context": {"identity": {"user": "read_only_user"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "analytics_prod",
				"schemaName": "tiny",
				"tableName": "orders",
			}},
		},
	}
}

test_read_only_user_can_browse_schemas if {
	trino.allow with input as {
		"context": {"identity": {"user": "read_only_user"}},
		"action": {"operation": "ShowSchemas"},
	}
}

test_read_only_user_denied_write if {
	not trino.allow with input as {
		"context": {"identity": {"user": "read_only_user"}},
		"action": {
			"operation": "InsertIntoTable",
			"resource": {"table": {
				"catalogName": "analytics_prod",
				"schemaName": "tiny",
				"tableName": "orders",
			}},
		},
	}
}

test_read_only_user_denied_sandbox if {
	not trino.allow with input as {
		"context": {"identity": {"user": "read_only_user"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "sandbox",
				"schemaName": "dev_alice",
				"tableName": "test",
			}},
		},
	}
}

test_read_only_user_batch_filters_catalogs if {
	allowed := trino.batch with input as {
		"context": {"identity": {"user": "read_only_user"}},
		"action": {"filterResources": [
			{"catalog": {"name": "analytics_prod"}},
			{"catalog": {"name": "sandbox"}},
		]},
	}
	allowed == {0}
}

# ── Analyst users ─────────────────────────────────────────────────────────────

test_analyst_can_select_bi_prod if {
	trino.allow with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "bi_prod",
				"schemaName": "tiny",
				"tableName": "orders",
			}},
		},
	}
}

test_analyst_can_write_dev_schema if {
	trino.allow with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {
			"operation": "InsertIntoTable",
			"resource": {"table": {
				"catalogName": "sandbox",
				"schemaName": "dev_alice",
				"tableName": "test",
			}},
		},
	}
}

test_analyst_denied_write_non_dev_schema if {
	not trino.allow with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {
			"operation": "InsertIntoTable",
			"resource": {"table": {
				"catalogName": "sandbox",
				"schemaName": "production",
				"tableName": "data",
			}},
		},
	}
}

test_analyst_denied_analytics_prod if {
	not trino.allow with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "analytics_prod",
				"schemaName": "tiny",
				"tableName": "orders",
			}},
		},
	}
}

test_analyst_batch_allows_bi_prod if {
	allowed := trino.batch with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {"filterResources": [
			{"catalog": {"name": "bi_prod"}},
			{"catalog": {"name": "analytics_prod"}},
		]},
	}
	allowed == {0}
}

# ── Default deny ──────────────────────────────────────────────────────────────

test_unknown_user_denied if {
	not trino.allow with input as {
		"context": {"identity": {"user": "hacker"}},
		"action": {"operation": "ExecuteQuery", "resource": {}},
	}
}

test_empty_input_denied if {
	not trino.allow with input as {}
}
