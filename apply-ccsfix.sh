#!/usr/bin/env bash
set -euo pipefail

if [ ! -f "frontend/src/views/user/KeysView.vue" ]; then
  echo "error: must run from sub2api repository root" >&2
  exit 1
fi

cat > frontend/src/utils/ccswitchImport.ts <<'EOF'
import type { GroupPlatform } from '@/types'

export const OPENAI_CC_SWITCH_CODEX_MODEL = 'gpt-5.4'

export type CcSwitchClientType = 'claude' | 'gemini'

export interface CcSwitchImportConfig {
  app: string
  endpoint: string
  model?: string
}

export interface CcSwitchImportDeeplinkInput {
  baseUrl: string
  platform?: GroupPlatform | null
  clientType: CcSwitchClientType
  providerName: string
  apiKey: string
  usageScript: string
}

export function buildCcSwitchUsageScript(baseUrl: string, apiKey: string): string {
  const normalizedBaseUrl = baseUrl.replace(/\/+$/, '')
  const usageEndpoint = `${normalizedBaseUrl}/v1/usage?days=30`
  const usageAuthHeader = `Bearer ${apiKey}`

  return `({
    request: {
      url: ${JSON.stringify(usageEndpoint)},
      method: "GET",
      headers: {
        "Authorization": ${JSON.stringify(usageAuthHeader)},
        "User-Agent": "cc-switch/1.0",
        "Accept": "application/json"
      }
    },
    extractor: function(response) {
      function n(value, fallback) {
        return typeof value === "number" && isFinite(value) ? value : fallback;
      }
      function usageCost(data) {
        if (!data || !data.usage || !data.usage.total) return 0;
        return n(data.usage.total.actual_cost, n(data.usage.total.cost, 0));
      }
      if (!response) {
        return { isValid: false, invalidMessage: "Empty Sub2API response" };
      }
      if (response.error) {
        return { isValid: false, invalidMessage: response.error.message || "Sub2API query failed" };
      }
      if (response.isValid === false) {
        return { isValid: false, invalidMessage: response.invalidMessage || response.message || "Invalid API key" };
      }
      var unit = response.unit || (response.quota && response.quota.unit) || "USD";
      var planName = response.planName || response.plan_name || response.mode || "Sub2API";
      if (response.quota) {
        var used = n(response.quota.used, 0);
        var remaining = n(response.quota.remaining, n(response.remaining, 0));
        var total = n(response.quota.limit, used + remaining);
        return { isValid: true, planName: planName, remaining: remaining, used: used, total: total, unit: unit };
      }
      if (response.subscription) {
        var sub = response.subscription;
        var subTotal = n(sub.monthly_limit_usd, n(sub.weekly_limit_usd, n(sub.daily_limit_usd, null)));
        var subUsed = n(sub.monthly_usage_usd, n(sub.weekly_usage_usd, n(sub.daily_usage_usd, usageCost(response))));
        var subRemaining = n(response.remaining, typeof subTotal === "number" ? Math.max(subTotal - subUsed, 0) : null);
        return { isValid: true, planName: planName, remaining: subRemaining, used: subUsed, total: subTotal, unit: unit };
      }
      var balance = n(response.remaining, n(response.balance, 0));
      var spent = usageCost(response);
      return { isValid: true, planName: planName, remaining: balance, used: spent, total: spent + balance, unit: unit };
    }
  })`
}

export function resolveCcSwitchImportConfig(
  platform: GroupPlatform | undefined | null,
  clientType: CcSwitchClientType,
  baseUrl: string
): CcSwitchImportConfig {
  switch (platform || 'anthropic') {
    case 'antigravity':
      return {
        app: clientType === 'gemini' ? 'gemini' : 'claude',
        endpoint: `${baseUrl}/antigravity`
      }
    case 'openai':
      return {
        app: 'codex',
        endpoint: baseUrl,
        model: OPENAI_CC_SWITCH_CODEX_MODEL
      }
    case 'gemini':
      return {
        app: 'gemini',
        endpoint: baseUrl
      }
    default:
      return {
        app: 'claude',
        endpoint: baseUrl
      }
  }
}

export function buildCcSwitchImportDeeplink(input: CcSwitchImportDeeplinkInput): string {
  const config = resolveCcSwitchImportConfig(input.platform, input.clientType, input.baseUrl)
  const entries: [string, string][] = [
    ['resource', 'provider'],
    ['app', config.app],
    ['name', input.providerName],
    ['homepage', input.baseUrl],
    ['endpoint', config.endpoint],
    ['apiKey', input.apiKey],
    ['configFormat', 'json'],
    ['usageEnabled', 'true'],
    ['usageScript', btoa(input.usageScript)],
    ['usageAutoInterval', '30']
  ]

  if (config.model) {
    entries.splice(2, 0, ['model', config.model])
  }

  return `ccswitch://v1/import?${new URLSearchParams(entries).toString()}`
}
EOF

python3 - <<'PY'
from pathlib import Path

path = Path("frontend/src/views/user/KeysView.vue")
text = path.read_text(encoding="utf-8")

old_import = """import {
  buildCcSwitchImportDeeplink,
  type CcSwitchClientType
} from '@/utils/ccswitchImport'"""

new_import = """import {
  buildCcSwitchUsageScript,
  buildCcSwitchImportDeeplink,
  type CcSwitchClientType
} from '@/utils/ccswitchImport'"""

old_block = """const executeCcsImport = (row: ApiKey, clientType: CcSwitchClientType) => {
  const baseUrl = publicSettings.value?.api_base_url || window.location.origin
  const platform = row.group?.platform || 'anthropic'

  const usageScript = `({
    request: {
      url: "{{baseUrl}}/v1/usage",
      method: "GET",
      headers: { "Authorization": "Bearer {{apiKey}}" }
    },
    extractor: function(response) {
      const remaining = response?.remaining ?? response?.quota?.remaining ?? response?.balance;
      const unit = response?.unit ?? response?.quota?.unit ?? "USD";
      return {
        isValid: response?.is_active ?? response?.isValid ?? true,
        remaining,
        unit
      };
    }
  })`"""

new_block = """const executeCcsImport = (row: ApiKey, clientType: CcSwitchClientType) => {
  const baseUrl = publicSettings.value?.api_base_url || window.location.origin
  const platform = row.group?.platform || 'anthropic'
  const usageScript = buildCcSwitchUsageScript(baseUrl, row.key)"""

if old_import not in text:
    raise SystemExit("import snippet not found")
if old_block not in text:
    raise SystemExit("executeCcsImport snippet not found")

text = text.replace(old_import, new_import, 1)
text = text.replace(old_block, new_block, 1)
path.write_text(text, encoding="utf-8")
PY

echo "ccs fix applied"
