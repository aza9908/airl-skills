-- Права ИИ-слоя (/airl-ai): после установки модулей, когда m_<…> уже есть.

-- ИИ-слой: показатели модулей (только m_<…>) и пороги витрин; таблицы с вводом людей — нет.
GRANT USAGE ON SCHEMA mart_finance, mart_sales, mart_edu, mart_hr, mart_marketing TO ai_reader;
GRANT SELECT ON mart_finance.m_pnl_gross_margin, mart_finance.m_pnl_net_profit, mart_finance.m_pnl_cash_balance,
              mart_finance.m_receivables_overdue, mart_finance.m_receivables_overdue_share,
              mart_finance.m_bank_auto_match_rate, mart_finance.m_bank_unmatched_count,
              mart_finance.airl_settings,
              mart_sales.m_plan_completion, mart_sales.airl_settings,
              mart_edu.m_edu_at_risk,
              mart_hr.m_onboarding_on_time_rate, mart_hr.airl_settings,
              mart_marketing.m_mkt_budget_usage, mart_marketing.airl_settings
      TO ai_reader;
