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

if old_import in text:
    text = text.replace(old_import, new_import, 1)

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

if old_block in text:
    text = text.replace(old_block, new_block, 1)
else:
    marker = "const platform = row.group?.platform || 'anthropic'\n"
    if marker in text and "buildCcSwitchUsageScript(baseUrl, row.key)" not in text:
        text = text.replace(marker, marker + "  const usageScript = buildCcSwitchUsageScript(baseUrl, row.key)\n", 1)

path.write_text(text, encoding="utf-8")
PY

python3 - <<'PY'
from pathlib import Path

path = Path("backend/internal/service/update_service.go")
text = path.read_text(encoding="utf-8")

old_var = """var (
\tErrNoUpdateAvailable = infraerrors.Conflict("ALREADY_UP_TO_DATE", "no update available; current version is latest")
)
"""
new_var = """var (
\tErrNoUpdateAvailable = infraerrors.Conflict("ALREADY_UP_TO_DATE", "no update available; current version is latest")
\tErrUpdateUnsupportedInContainer = infraerrors.BadRequest("UPDATE_UNSUPPORTED_IN_CONTAINER", "online update is disabled for Docker deployments; please replace the Docker image and restart the container")
)
"""
if 'ErrUpdateUnsupportedInContainer' not in text and old_var in text:
    text = text.replace(old_var, new_var, 1)

text = text.replace('buildType      string // "source" for manual builds, "release" for CI builds\n', 'buildType      string // "source" for manual builds, "release" for standalone binaries, "docker" for container deployments\n', 1)
text = text.replace('BuildType      string       `json:"build_type"` // "source" or "release"\n', 'BuildType      string       `json:"build_type"` // "source", "release", or "docker"\n', 1)

old_ctor = """func NewUpdateService(cache UpdateCache, githubClient GitHubReleaseClient, version, buildType string) *UpdateService {
\treturn &UpdateService{
\t\tcache:          cache,
\t\tgithubClient:   githubClient,
\t\tcurrentVersion: version,
\t\tbuildType:      buildType,
\t}
}
"""
new_ctor = """func NewUpdateService(cache UpdateCache, githubClient GitHubReleaseClient, version, buildType string) *UpdateService {
\treturn &UpdateService{
\t\tcache:          cache,
\t\tgithubClient:   githubClient,
\t\tcurrentVersion: version,
\t\tbuildType:      normalizeBuildType(buildType),
\t}
}
"""
if old_ctor in text:
    text = text.replace(old_ctor, new_ctor, 1)

ctor_anchor = """func NewUpdateService(cache UpdateCache, githubClient GitHubReleaseClient, version, buildType string) *UpdateService {
\treturn &UpdateService{
\t\tcache:          cache,
\t\tgithubClient:   githubClient,
\t\tcurrentVersion: version,
\t\tbuildType:      normalizeBuildType(buildType),
\t}
}
"""
helper = """
func normalizeBuildType(buildType string) string {
\ttrimmed := strings.TrimSpace(strings.ToLower(buildType))
\tif trimmed == "" {
\t\ttrimmed = "source"
\t}
\tif trimmed == "release" && isDockerDeployment() {
\t\treturn "docker"
\t}
\treturn trimmed
}

func isDockerDeployment() bool {
\tif _, err := os.Stat("/.dockerenv"); err == nil {
\t\treturn true
\t}
\tif strings.TrimSpace(os.Getenv("KUBERNETES_SERVICE_HOST")) != "" {
\t\treturn true
\t}
\tif data, err := os.ReadFile("/proc/1/cgroup"); err == nil {
\t\tcontent := strings.ToLower(string(data))
\t\tif strings.Contains(content, "docker") || strings.Contains(content, "containerd") || strings.Contains(content, "kubepods") {
\t\t\treturn true
\t\t}
\t}
\treturn false
}
"""
if helper not in text and ctor_anchor in text:
    text = text.replace(ctor_anchor, ctor_anchor + helper, 1)

old_perform = """func (s *UpdateService) PerformUpdate(ctx context.Context) error {
\tinfo, err := s.CheckUpdate(ctx, true)
"""
new_perform = """func (s *UpdateService) PerformUpdate(ctx context.Context) error {
\tif s.buildType == "docker" {
\t\treturn ErrUpdateUnsupportedInContainer
\t}

\tinfo, err := s.CheckUpdate(ctx, true)
"""
if old_perform in text:
    text = text.replace(old_perform, new_perform, 1)

path.write_text(text, encoding="utf-8")
PY

python3 - <<'PY'
from pathlib import Path

path = Path("frontend/src/api/admin/system.ts")
text = path.read_text(encoding="utf-8")
text = text.replace(
    '  build_type: string // "source" for manual builds, "release" for CI builds\n',
    '  build_type: string // "source" for manual builds, "release" for standalone builds, "docker" for container deployments\n',
    1,
)
path.write_text(text, encoding="utf-8")
PY

python3 - <<'PY'
from pathlib import Path

path = Path("frontend/src/components/common/VersionBadge.vue")
text = path.read_text(encoding="utf-8")

start_marker = "              <!-- Priority 3: Update available for source build - show git pull hint -->"
end_marker = "              <!-- Priority 4: Update available for release build - show update button -->"
start = text.find(start_marker)
end = text.find(end_marker)
if start == -1 or end == -1 or end <= start:
    raise SystemExit("VersionBadge markers not found")

new_branch = """              <!-- Priority 3: Update available for Docker deployment - show image replacement hint -->
              <div v-else-if="hasUpdate && isDockerDeployment" class="space-y-2">
                <a
                  v-if="releaseInfo?.html_url && releaseInfo.html_url !== '#'"
                  :href="releaseInfo.html_url"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="group flex items-center gap-3 rounded-lg border border-amber-200 bg-amber-50 p-3 transition-colors hover:bg-amber-100 dark:border-amber-800/50 dark:bg-amber-900/20 dark:hover:bg-amber-900/30"
                >
                  <div
                    class="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-full bg-amber-100 dark:bg-amber-900/50"
                  >
                    <Icon
                      name="download"
                      size="sm"
                      :stroke-width="2"
                      class="text-amber-600 dark:text-amber-400"
                    />
                  </div>
                  <div class="min-w-0 flex-1">
                    <p class="text-sm font-medium text-amber-700 dark:text-amber-300">
                      {{ t('version.updateAvailable') }}
                    </p>
                    <p class="text-xs text-amber-600/70 dark:text-amber-400/70">
                      v{{ latestVersion }}
                    </p>
                  </div>
                  <svg
                    class="h-4 w-4 text-amber-500 transition-transform group-hover:translate-x-0.5 dark:text-amber-400"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    stroke-width="2"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
                  </svg>
                </a>
                <div
                  class="flex items-center gap-2 rounded-lg border border-blue-200 bg-blue-50 p-2 dark:border-blue-800/50 dark:bg-blue-900/20"
                >
                  <svg
                    class="h-3.5 w-3.5 flex-shrink-0 text-blue-500 dark:text-blue-400"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    stroke-width="2"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <p class="text-xs text-blue-600 dark:text-blue-400">
                    {{ t('version.dockerModeHint') }}
                  </p>
                </div>
              </div>

              <!-- Priority 4: Update available for source build - show git pull hint -->
              <div v-else-if="hasUpdate && !isReleaseBuild && !isDockerDeployment" class="space-y-2">
                <a
                  v-if="releaseInfo?.html_url && releaseInfo.html_url !== '#'"
                  :href="releaseInfo.html_url"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="group flex items-center gap-3 rounded-lg border border-amber-200 bg-amber-50 p-3 transition-colors hover:bg-amber-100 dark:border-amber-800/50 dark:bg-amber-900/20 dark:hover:bg-amber-900/30"
                >
                  <div
                    class="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-full bg-amber-100 dark:bg-amber-900/50"
                  >
                    <Icon
                      name="download"
                      size="sm"
                      :stroke-width="2"
                      class="text-amber-600 dark:text-amber-400"
                    />
                  </div>
                  <div class="min-w-0 flex-1">
                    <p class="text-sm font-medium text-amber-700 dark:text-amber-300">
                      {{ t('version.updateAvailable') }}
                    </p>
                    <p class="text-xs text-amber-600/70 dark:text-amber-400/70">
                      v{{ latestVersion }}
                    </p>
                  </div>
                  <svg
                    class="h-4 w-4 text-amber-500 transition-transform group-hover:translate-x-0.5 dark:text-amber-400"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    stroke-width="2"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
                  </svg>
                </a>
                <div
                  class="flex items-center gap-2 rounded-lg border border-blue-200 bg-blue-50 p-2 dark:border-blue-800/50 dark:bg-blue-900/20"
                >
                  <svg
                    class="h-3.5 w-3.5 flex-shrink-0 text-blue-500 dark:text-blue-400"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    stroke-width="2"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <p class="text-xs text-blue-600 dark:text-blue-400">
                    {{ t('version.sourceModeHint') }}
                  </p>
                </div>
              </div>

"""

text = text[:start] + new_branch + text[end:]
text = text.replace(
    "              <!-- Priority 5: Up to date - show GitHub link -->",
    "              <!-- Priority 6: Up to date - show GitHub link -->",
    1,
)
if "const isDockerDeployment = computed(() => buildType.value === 'docker')" not in text:
    text = text.replace(
        "const isReleaseBuild = computed(() => buildType.value === 'release')\n",
        "const isReleaseBuild = computed(() => buildType.value === 'release')\nconst isDockerDeployment = computed(() => buildType.value === 'docker')\n",
        1,
    )

path.write_text(text, encoding="utf-8")
PY

python3 - <<'PY'
from pathlib import Path

def insert_after_key(path_str: str, anchor_key: str, line: str):
    path = Path(path_str)
    text = path.read_text(encoding="utf-8")
    if line in text:
        return
    anchor = f"    {anchor_key}:"
    idx = text.find(anchor)
    if idx == -1:
        raise SystemExit(f"anchor not found in {path_str}: {anchor_key}")
    line_end = text.find("\n", idx)
    if line_end == -1:
        raise SystemExit(f"line end not found in {path_str}: {anchor_key}")
    text = text[: line_end + 1] + line + text[line_end + 1 :]
    path.write_text(text, encoding="utf-8")

insert_after_key(
    "frontend/src/i18n/locales/zh.ts",
    "sourceModeHint",
    "    dockerModeHint: 'Docker 部署不支持在线更新，请替换镜像并重建容器',\n",
)
insert_after_key(
    "frontend/src/i18n/locales/en.ts",
    "sourceModeHint",
    "    dockerModeHint: 'Docker deployments do not support in-app updates. Replace the image and recreate the container.',\n",
)
PY

python3 - <<'PY'
from pathlib import Path

path = Path("backend/internal/handler/admin/system_handler_test.go")
text = path.read_text(encoding="utf-8")

if "func TestSystemHandlerPerformUpdateDockerReturnsBadRequest" not in text:
    addition = """
func TestSystemHandlerPerformUpdateDockerReturnsBadRequest(t *testing.T) {
\tupdateSvc := &systemHandlerUpdateServiceStub{
\t\tperformErr: service.ErrUpdateUnsupportedInContainer,
\t}
\trepo := newMemoryIdempotencyRepoStub()
\trouter := newSystemHandlerTestRouter(t, updateSvc, repo)

\trec := httptest.NewRecorder()
\treq := httptest.NewRequest(http.MethodPost, "/api/v1/admin/system/update", nil)
\treq.Header.Set("Idempotency-Key", "docker-update-disabled")
\trouter.ServeHTTP(rec, req)

\trequire.Equal(t, http.StatusBadRequest, rec.Code)
\trequire.Equal(t, 1, updateSvc.performCall)
\trequire.Empty(t, updateSvc.checkForces)
\trequireSystemLockStatus(t, repo, service.IdempotencyStatusFailedRetryable)

\tvar body systemUpdateErrorEnvelope
\trequire.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
\trequire.Equal(t, http.StatusBadRequest, body.Code)
\trequire.Equal(t, "online update is disabled for Docker deployments; please replace the Docker image and restart the container", body.Message)
}
"""
    marker = "\nfunc TestSystemHandlerPerformUpdateFailureStillReturnsInternalError(t *testing.T) {\n"
    if marker not in text:
        raise SystemExit("system_handler_test insertion marker not found")
    text = text.replace(marker, addition + marker, 1)

path.write_text(text, encoding="utf-8")
PY

echo "ccs fix + docker safe update fix applied"
