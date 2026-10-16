# Alerts only — a budget never stops services. Emails go to billing admins.
resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account_id
  display_name    = "monthly-cap-${var.budget_amount_inr}"

  amount {
    specified_amount {
      currency_code = "INR"
      units         = tostring(var.budget_amount_inr)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  depends_on = [google_project_service.this]
}
