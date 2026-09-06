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
			{"catalog": {"name": "powerschool"}},
			{"catalog": {"name": "illuminate"}},
			{"catalog": {"name": "bi_prod"}},
			{"catalog": {"name": "sandbox"}},
		]},
	}
	allowed == {0, 1, 2, 3}
}

# ── read_only_user ────────────────────────────────────────────────────────────

test_read_only_user_can_select_powerschool if {
	trino.allow with input as {
		"context": {"identity": {"user": "read_only_user"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "powerschool",
				"schemaName": "tiny",
				"tableName": "student",
			}},
		},
	}
}

test_read_only_user_can_select_illuminate if {
	trino.allow with input as {
		"context": {"identity": {"user": "read_only_user"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "illuminate",
				"schemaName": "tiny",
				"tableName": "assessment",
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
				"catalogName": "powerschool",
				"schemaName": "tiny",
				"tableName": "student",
			}},
		},
	}
}

test_read_only_user_denied_bi_prod if {
	not trino.allow with input as {
		"context": {"identity": {"user": "read_only_user"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "bi_prod",
				"schemaName": "reporting",
				"tableName": "dashboard",
			}},
		},
	}
}

test_read_only_user_batch_sees_only_source_catalogs if {
	allowed := trino.batch with input as {
		"context": {"identity": {"user": "read_only_user"}},
		"action": {"filterResources": [
			{"catalog": {"name": "powerschool"}},
			{"catalog": {"name": "illuminate"}},
			{"catalog": {"name": "bi_prod"}},
			{"catalog": {"name": "sandbox"}},
		]},
	}
	allowed == {0, 1}
}

# ── bi_developer ──────────────────────────────────────────────────────────────

test_bi_developer_can_select_source_data if {
	trino.allow with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "powerschool",
				"schemaName": "tiny",
				"tableName": "student",
			}},
		},
	}
}

test_bi_developer_can_select_bi_prod if {
	trino.allow with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "bi_prod",
				"schemaName": "reporting",
				"tableName": "dashboard",
			}},
		},
	}
}

test_bi_developer_can_write_dev_schema_in_bi_prod if {
	trino.allow with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {
			"operation": "InsertIntoTable",
			"resource": {"table": {
				"catalogName": "bi_prod",
				"schemaName": "dev_alice",
				"tableName": "enrollment_report",
			}},
		},
	}
}

test_bi_developer_denied_write_non_dev_schema if {
	not trino.allow with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {
			"operation": "InsertIntoTable",
			"resource": {"table": {
				"catalogName": "bi_prod",
				"schemaName": "reporting",
				"tableName": "dashboard",
			}},
		},
	}
}

test_bi_developer_denied_sandbox_write if {
	not trino.allow with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {
			"operation": "InsertIntoTable",
			"resource": {"table": {
				"catalogName": "sandbox",
				"schemaName": "dev_alice",
				"tableName": "model",
			}},
		},
	}
}

test_bi_developer_batch_sees_source_and_bi if {
	allowed := trino.batch with input as {
		"context": {"identity": {"user": "alice"}},
		"action": {"filterResources": [
			{"catalog": {"name": "powerschool"}},
			{"catalog": {"name": "illuminate"}},
			{"catalog": {"name": "bi_prod"}},
			{"catalog": {"name": "sandbox"}},
		]},
	}
	allowed == {0, 1, 2}
}

# ── dbt_developer ─────────────────────────────────────────────────────────────

test_dbt_developer_can_select_source_data if {
	trino.allow with input as {
		"context": {"identity": {"user": "charlie"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "illuminate",
				"schemaName": "tiny",
				"tableName": "assessment",
			}},
		},
	}
}

test_dbt_developer_can_write_dev_schema_in_sandbox if {
	trino.allow with input as {
		"context": {"identity": {"user": "charlie"}},
		"action": {
			"operation": "InsertIntoTable",
			"resource": {"table": {
				"catalogName": "sandbox",
				"schemaName": "dev_charlie",
				"tableName": "stg_students",
			}},
		},
	}
}

test_dbt_developer_denied_bi_prod if {
	not trino.allow with input as {
		"context": {"identity": {"user": "charlie"}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "bi_prod",
				"schemaName": "reporting",
				"tableName": "dashboard",
			}},
		},
	}
}

test_dbt_developer_denied_write_non_dev_schema if {
	not trino.allow with input as {
		"context": {"identity": {"user": "charlie"}},
		"action": {
			"operation": "InsertIntoTable",
			"resource": {"table": {
				"catalogName": "sandbox",
				"schemaName": "production",
				"tableName": "model",
			}},
		},
	}
}

test_dbt_developer_batch_sees_only_source_catalogs if {
	allowed := trino.batch with input as {
		"context": {"identity": {"user": "charlie"}},
		"action": {"filterResources": [
			{"catalog": {"name": "powerschool"}},
			{"catalog": {"name": "illuminate"}},
			{"catalog": {"name": "bi_prod"}},
			{"catalog": {"name": "sandbox"}},
		]},
	}
	allowed == {0, 1}
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
