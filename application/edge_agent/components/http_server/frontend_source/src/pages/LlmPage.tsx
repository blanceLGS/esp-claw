import { createEffect, createMemo, createSignal, Show, type Component } from 'solid-js';
import { t } from '../i18n';
import type { AppConfig } from '../api/client';
import { createConfigTab } from '../state/configTab';
import { TabShell } from '../components/layout/TabShell';
import { PageHeader } from '../components/ui/PageHeader';
import { CollapsibleConfigBlock, StaticConfigBlock } from '../components/ui/ConfigBlocks';
import { TextInput, SelectInput } from '../components/ui/FormField';
import { SavePanel } from '../components/ui/SavePanel';
import { Banner } from '../components/ui/Banner';
import { Switch } from '../components/ui/Switch';
import { Button } from '../components/ui/Button';
import { LabelLink } from '../components/ui/LabelLink';
import { getProviderLinks } from '../constants/externalLinks';
import { pushToast } from '../state/toast';

type PresetKey =
  | 'openai'
  | 'bailian'
  | 'deepseek'
  | 'anthropic'
  | 'kimi_global'
  | 'kimi_cn'
  | 'minimax_global'
  | 'minimax_cn'
  | 'anthropic_compatible'
  | 'openai_compatible';

type ProviderPreset = {
  llm_backend_type: string;
  llm_base_url: string;
  llm_auth_type: string;
  llm_max_tokens_field: string;
  llm_default_image_max_bytes: string;
  llm_supports_tools: boolean;
  llm_supports_vision: boolean;
  llm_image_remote_url_only: boolean;
  llm_model: string;
  advanced: boolean;
};

const PROVIDER_PRESETS: Record<PresetKey, ProviderPreset> = {
  openai: {
    llm_backend_type: 'openai_compatible',
    llm_base_url: 'https://api.openai.com/v1',
    llm_auth_type: 'bearer',
    llm_max_tokens_field: 'max_completion_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: true,
    llm_image_remote_url_only: false,
    llm_model: 'gpt-5.4',
    advanced: false,
  },
  bailian: {
    llm_backend_type: 'openai_compatible',
    llm_base_url: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    llm_auth_type: 'bearer',
    llm_max_tokens_field: 'max_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: true,
    llm_image_remote_url_only: false,
    llm_model: 'qwen3.6-plus',
    advanced: false,
  },
  deepseek: {
    llm_backend_type: 'openai_compatible',
    llm_base_url: 'https://api.deepseek.com',
    llm_auth_type: 'bearer',
    llm_max_tokens_field: 'max_completion_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: false,
    llm_image_remote_url_only: false,
    llm_model: 'deepseek-v4-pro',
    advanced: false,
  },
  anthropic: {
    llm_backend_type: 'anthropic_compatible',
    llm_base_url: 'https://api.anthropic.com/v1',
    llm_auth_type: 'none',
    llm_max_tokens_field: 'max_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: true,
    llm_image_remote_url_only: false,
    llm_model: 'claude-sonnet-4-6',
    advanced: false,
  },
  kimi_global: {
    llm_backend_type: 'openai_compatible',
    llm_base_url: 'https://api.moonshot.ai/v1',
    llm_auth_type: 'bearer',
    llm_max_tokens_field: 'max_completion_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: true,
    llm_image_remote_url_only: false,
    llm_model: 'kimi-k2.6',
    advanced: false,
  },
  kimi_cn: {
    llm_backend_type: 'openai_compatible',
    llm_base_url: 'https://api.moonshot.cn/v1',
    llm_auth_type: 'bearer',
    llm_max_tokens_field: 'max_completion_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: true,
    llm_image_remote_url_only: false,
    llm_model: 'kimi-k2.6',
    advanced: false,
  },
  minimax_global: {
    llm_backend_type: 'anthropic_compatible',
    llm_base_url: 'https://api.minimaxi.io/anthropic',
    llm_auth_type: 'none',
    llm_max_tokens_field: 'max_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: true,
    llm_image_remote_url_only: false,
    llm_model: 'MiniMax-M3',
    advanced: false,
  },
  minimax_cn: {
    llm_backend_type: 'anthropic_compatible',
    llm_base_url: 'https://api.minimaxi.com/anthropic',
    llm_auth_type: 'none',
    llm_max_tokens_field: 'max_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: true,
    llm_image_remote_url_only: false,
    llm_model: 'MiniMax-M3',
    advanced: false,
  },
  openai_compatible: {
    llm_backend_type: 'openai_compatible',
    llm_base_url: 'https://api.openai.com/v1',
    llm_auth_type: 'bearer',
    llm_max_tokens_field: 'max_completion_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: true,
    llm_image_remote_url_only: false,
    llm_model: 'gpt-5.4',
    advanced: true,
  },
  anthropic_compatible: {
    llm_backend_type: 'anthropic_compatible',
    llm_base_url: 'https://api.anthropic.com/v1',
    llm_auth_type: 'none',
    llm_max_tokens_field: 'max_tokens',
    llm_default_image_max_bytes: '524288',
    llm_supports_tools: true,
    llm_supports_vision: true,
    llm_image_remote_url_only: false,
    llm_model: 'claude-sonnet-4-6',
    advanced: true,
  },
};

const PRESET_BUTTONS: PresetKey[] = [
  'openai',
  'bailian',
  'deepseek',
  'anthropic',
  'kimi_global',
  'kimi_cn',
  'minimax_global',
  'minimax_cn',
  'openai_compatible',
  'anthropic_compatible',
];

type LlmForm = {
  llm_api_key: string;
  llm_model: string;
  llm_timeout_ms: string;
  llm_max_tokens: string;
  llm_backend_type: string;
  llm_base_url: string;
  llm_auth_type: string;
  llm_default_image_max_bytes: string;
  llm_max_tokens_field: string;
  llm_supports_tools: boolean;
  llm_supports_vision: boolean;
  llm_image_remote_url_only: boolean;
  asr_provider: string;
  asr_api_key: string;
  asr_api_secret: string;
  asr_app_id: string;
  asr_model: string;
  asr_endpoint: string;
  voice_wake_words: string;
  voice_enable: string;
  tts_api_key: string;
  tts_base_url: string;
  tts_model: string;
  tts_voice: string;
  tts_volume: string;
};

function isPositiveInteger(value: string): boolean {
  return /^[1-9]\d*$/.test(value);
}

function parseBool(value: string | undefined): boolean {
  return value === 'true' || value === '1';
}

function presetLabel(key: PresetKey): string {
  switch (key) {
    case 'openai':
      return t('llmProviderOpenai') as string;
    case 'bailian':
      return t('setupLlmProviderBailian') as string;
    case 'deepseek':
      return t('llmProviderDeepSeek') as string;
    case 'anthropic':
      return t('llmProviderAnthropic') as string;
    case 'kimi_global':
      return t('llmProviderKimiGlobal') as string;
    case 'kimi_cn':
      return t('llmProviderKimiCn') as string;
    case 'minimax_global':
      return t('llmProviderMinimaxGlobal') as string;
    case 'minimax_cn':
      return t('llmProviderMinimaxCn') as string;
    case 'openai_compatible':
      return t('llmProviderOpenaiCompatible') as string;
    case 'anthropic_compatible':
      return t('llmProviderAnthropicCompatible') as string;
  }
}

export const LlmPage: Component = () => {
  const tab = createConfigTab<LlmForm>({
    tab: 'llm',
    groups: ['llm', 'voice'],
    toForm: (config: Partial<AppConfig>) => ({
      llm_api_key: config.llm_api_key ?? '',
      llm_model: config.llm_model ?? '',
      llm_timeout_ms: config.llm_timeout_ms ?? '',
      llm_max_tokens: config.llm_max_tokens ?? '',
      llm_backend_type: config.llm_backend_type ?? '',
      llm_base_url: config.llm_base_url ?? '',
      llm_auth_type: config.llm_auth_type ?? '',
      llm_default_image_max_bytes: config.llm_default_image_max_bytes ?? '',
      llm_max_tokens_field: config.llm_max_tokens_field ?? '',
      llm_supports_tools: parseBool(config.llm_supports_tools),
      llm_supports_vision: parseBool(config.llm_supports_vision),
      llm_image_remote_url_only: parseBool(config.llm_image_remote_url_only),
      asr_provider: config.asr_provider ?? '',
      asr_api_key: config.asr_api_key ?? '',
      asr_api_secret: config.asr_api_secret ?? '',
      asr_app_id: config.asr_app_id ?? '',
      asr_model: config.asr_model ?? '',
      asr_endpoint: config.asr_endpoint ?? '',
      voice_wake_words: config.voice_wake_words ?? '',
      voice_enable: config.voice_enable ?? 'true',
      tts_api_key: config.tts_api_key ?? '',
      tts_base_url: config.tts_base_url ?? '',
      tts_model: config.tts_model ?? '',
      tts_voice: config.tts_voice ?? '',
      tts_volume: config.tts_volume ?? '80',
    }),
    fromForm: (form) => ({
      llm_api_key: form.llm_api_key.trim(),
      llm_model: form.llm_model.trim(),
      llm_timeout_ms: form.llm_timeout_ms.trim(),
      llm_max_tokens: form.llm_max_tokens.trim(),
      llm_backend_type: form.llm_backend_type.trim(),
      llm_base_url: form.llm_base_url.trim(),
      llm_auth_type: form.llm_auth_type.trim(),
      llm_default_image_max_bytes: form.llm_default_image_max_bytes.trim(),
      llm_max_tokens_field: form.llm_max_tokens_field.trim(),
      llm_supports_tools: String(form.llm_supports_tools),
      llm_supports_vision: String(form.llm_supports_vision),
      llm_image_remote_url_only: String(form.llm_image_remote_url_only),
      asr_provider: form.asr_provider.trim(),
      asr_api_key: form.asr_api_key.trim(),
      asr_api_secret: form.asr_api_secret.trim(),
      asr_app_id: form.asr_app_id.trim(),
      asr_model: form.asr_model.trim(),
      asr_endpoint: form.asr_endpoint.trim(),
      voice_wake_words: form.voice_wake_words.trim(),
      voice_enable: parseBool(form.voice_enable) ? 'true' : 'false',
      tts_api_key: form.tts_api_key.trim(),
      tts_base_url: form.tts_base_url.trim(),
      tts_model: form.tts_model.trim(),
      tts_voice: form.tts_voice.trim(),
      tts_volume: form.tts_volume.trim(),
    }),
  });
  const [validationError, setValidationError] = createSignal<string | null>(null);
  const [advancedOpen, setAdvancedOpen] = createSignal(false);
  const [selectedPreset, setSelectedPreset] = createSignal<PresetKey | null>(null);
  const providerLinks = createMemo(() => {
    const key = selectedPreset();
    return key ? getProviderLinks(key) : undefined;
  });

  createEffect(() => {
    void tab.form.llm_api_key;
    void tab.form.llm_model;
    void tab.form.llm_max_tokens;
    void tab.form.llm_backend_type;
    void tab.form.llm_base_url;
    void tab.form.llm_auth_type;
    void tab.form.llm_default_image_max_bytes;
    void tab.form.llm_max_tokens_field;
    void tab.form.llm_supports_tools;
    void tab.form.llm_supports_vision;
    void tab.form.llm_image_remote_url_only;
    void tab.form.asr_provider;
    void tab.form.asr_api_key;
    void tab.form.asr_api_secret;
    void tab.form.asr_app_id;
    void tab.form.asr_model;
    void tab.form.asr_endpoint;
    void tab.form.voice_wake_words;
    void tab.form.voice_enable;
    void tab.form.tts_api_key;
    void tab.form.tts_base_url;
    void tab.form.tts_model;
    void tab.form.tts_voice;
    void tab.form.tts_volume;
    setValidationError(null);
  });

  const applyPreset = (key: PresetKey) => {
    const preset = PROVIDER_PRESETS[key];
    tab.setForm('llm_backend_type', preset.llm_backend_type);
    tab.setForm('llm_base_url', preset.llm_base_url);
    tab.setForm('llm_auth_type', preset.llm_auth_type);
    tab.setForm('llm_max_tokens_field', preset.llm_max_tokens_field);
    tab.setForm('llm_default_image_max_bytes', preset.llm_default_image_max_bytes);
    tab.setForm('llm_supports_tools', preset.llm_supports_tools);
    tab.setForm('llm_supports_vision', preset.llm_supports_vision);
    tab.setForm('llm_image_remote_url_only', preset.llm_image_remote_url_only);
    tab.setForm('llm_model', preset.llm_model);
    setSelectedPreset(key);
    setAdvancedOpen(preset.advanced);
  };

  const handleSave = async () => {
    const requiredFields: Array<[keyof LlmForm, string]> = [
      ['llm_api_key', t('llmApiKey') as string],
      ['llm_model', t('llmModel') as string],
      ['llm_max_tokens', t('llmMaxTokens') as string],
      ['llm_backend_type', t('llmBackend') as string],
      ['llm_base_url', t('llmBaseUrl') as string],
      ['llm_auth_type', t('llmAuthType') as string],
      ['llm_default_image_max_bytes', t('llmDefaultImageMaxBytes') as string],
      ['llm_max_tokens_field', t('llmMaxTokensField') as string],
    ];
    const missing = requiredFields
      .filter(([key]) => typeof tab.form[key] === 'string' && !(tab.form[key] as string).trim())
      .map(([, label]) => label);

    if (missing.length > 0) {
      const message = (t('llmValidationRequiredFields') as string).replace(
        '{fields}',
        missing.join(' / '),
      );
      setValidationError(message);
      pushToast(message, 'error', 5000);
      return;
    }

    if (!isPositiveInteger(tab.form.llm_max_tokens.trim())) {
      const message = t('llmValidationMaxTokens') as string;
      setValidationError(message);
      pushToast(message, 'error', 5000);
      return;
    }

    if (!isPositiveInteger(tab.form.llm_default_image_max_bytes.trim())) {
      const message = t('llmValidationImageMaxBytes') as string;
      setValidationError(message);
      pushToast(message, 'error', 5000);
      return;
    }

    await tab.save();
  };

  return (
    <TabShell>
      <PageHeader title={t('navLlm') as string} description={t('sectionLlm') as string} />
      <Show when={validationError() ?? tab.error()}>
        <div class="px-5 pt-4">
          <Banner kind="error" message={validationError() ?? tab.error() ?? undefined} />
        </div>
      </Show>
      <div class="divide-y divide-[var(--color-border-subtle)] mt-2">
        <StaticConfigBlock title={t('sectionLlm') as string}>
          <div class="flex flex-col gap-3 pt-2">
            <div class="flex flex-col gap-2">
              <div class="text-[0.8rem] text-[var(--color-text-secondary)] font-medium">
                {t('llmFillDefaults') as string}
              </div>
              <div class="flex flex-wrap gap-2">
                {PRESET_BUTTONS.map((key) => (
                  <Button
                    size="sm"
                    variant="secondary"
                    active={selectedPreset() === key}
                    onClick={() => applyPreset(key)}
                  >
                    {presetLabel(key)}
                  </Button>
                ))}
              </div>
            </div>
            <div class="grid gap-3 sm:grid-cols-2">
              <TextInput
                type="password"
                label={
                  <>
                    {t('llmApiKey')}
                    <Show when={providerLinks()}>
                      {(links) => (
                        <LabelLink href={links().consoleUrl}>
                          {t('llmProviderConsole') as string} ↗
                        </LabelLink>
                      )}
                    </Show>
                  </>
                }
                value={tab.form.llm_api_key}
                onInput={(event) => tab.setForm('llm_api_key', event.currentTarget.value)}
              />
              <TextInput
                label={
                  <>
                    {t('llmModel')}
                    <Show when={providerLinks()}>
                      {(links) => (
                        <LabelLink href={links().docsUrl}>
                          {t('llmProviderDocs') as string} ↗
                        </LabelLink>
                      )}
                    </Show>
                  </>
                }
                value={tab.form.llm_model}
                onInput={(event) => tab.setForm('llm_model', event.currentTarget.value)}
              />
              <TextInput
                label={t('llmMaxTokens')}
                placeholder={t('llmMaxTokensPlaceholder') as string}
                value={tab.form.llm_max_tokens}
                onInput={(event) => tab.setForm('llm_max_tokens', event.currentTarget.value)}
              />
            </div>
          </div>
        </StaticConfigBlock>
        <CollapsibleConfigBlock
          title={t('llmAdvanced') as string}
          defaultOpen={false}
          open={advancedOpen()}
          onOpenChange={setAdvancedOpen}
        >
          <div class="grid gap-3 sm:grid-cols-2 pt-2">
            <TextInput
              label={t('llmBackend')}
              placeholder={t('llmBackendPlaceholder') as string}
              value={tab.form.llm_backend_type}
              onInput={(event) => tab.setForm('llm_backend_type', event.currentTarget.value)}
            />
            <TextInput
              type="url"
              label={t('llmBaseUrl')}
              placeholder={t('llmBaseUrlPlaceholder') as string}
              value={tab.form.llm_base_url}
              onInput={(event) => tab.setForm('llm_base_url', event.currentTarget.value)}
            />
            <TextInput
              label={t('llmAuthType')}
              placeholder={t('llmAuthTypePlaceholder') as string}
              value={tab.form.llm_auth_type}
              onInput={(event) => tab.setForm('llm_auth_type', event.currentTarget.value)}
            />
            <TextInput
              label={t('llmMaxTokensField')}
              placeholder={t('llmMaxTokensFieldPlaceholder') as string}
              value={tab.form.llm_max_tokens_field}
              onInput={(event) => tab.setForm('llm_max_tokens_field', event.currentTarget.value)}
            />
            <TextInput
              label={t('llmDefaultImageMaxBytes')}
              placeholder={t('llmDefaultImageMaxBytesPlaceholder') as string}
              value={tab.form.llm_default_image_max_bytes}
              onInput={(event) =>
                tab.setForm('llm_default_image_max_bytes', event.currentTarget.value)
              }
            />
            <TextInput
              label={t('llmTimeout')}
              placeholder={t('llmTimeoutPlaceholder') as string}
              value={tab.form.llm_timeout_ms}
              onInput={(event) => tab.setForm('llm_timeout_ms', event.currentTarget.value)}
            />
            <div class="flex items-start">
              <Switch
                checked={tab.form.llm_supports_tools}
                onChange={(checked) => tab.setForm('llm_supports_tools', checked)}
                label={t('llmSupportsTools') as string}
              />
            </div>
            <div class="flex items-start">
              <Switch
                checked={tab.form.llm_supports_vision}
                onChange={(checked) => tab.setForm('llm_supports_vision', checked)}
                label={t('llmSupportsVision') as string}
              />
            </div>
            <div class="flex items-start">
              <Switch
                checked={tab.form.llm_image_remote_url_only}
                onChange={(checked) => tab.setForm('llm_image_remote_url_only', checked)}
                label={t('llmImageRemoteUrlOnly') as string}
              />
            </div>
          </div>
        </CollapsibleConfigBlock>
        <CollapsibleConfigBlock title={t('voiceAsrSection') as string} defaultOpen={true}>
          <div class="grid gap-3 sm:grid-cols-2 pt-2">
            <SelectInput
              label={t('voiceAsrProvider') as string}
              hint={t('voiceAsrEngineHint') as string}
              value={tab.form.asr_provider}
              onChange={(event) => {
                const v = event.currentTarget.value;
                tab.setForm('asr_provider', v);
                if (v === 'iflytek_bigmodel') {
                  tab.setForm('asr_endpoint', 'wss://iat.xf-yun.com/v1');
                } else if (v === 'iflytek') {
                  tab.setForm('asr_endpoint', 'wss://iat-api.xfyun.cn/v2/iat');
                } else if (v === 'siliconflow') {
                  tab.setForm('asr_endpoint', 'https://api.siliconflow.cn/v1');
                }
              }}
            >
              <option value="">{t('voiceAsrProviderNone') as string}</option>
              <option value="iflytek">{t('voiceAsrProviderIflytek') as string}</option>
              <option value="iflytek_bigmodel">{t('voiceAsrProviderIflytekBigmodel') as string}</option>
              <option value="siliconflow">{t('voiceAsrProviderSiliconFlow') as string}</option>
            </SelectInput>
            <TextInput
              label={t('voiceWakeWords') as string}
              hint={t('voiceWakeWordsHint') as string}
              value={tab.form.voice_wake_words}
              onInput={(event) => tab.setForm('voice_wake_words', event.currentTarget.value)}
            />
            <div class="flex items-start">
              <Switch
                checked={parseBool(tab.form.voice_enable)}
                onChange={(checked) => tab.setForm('voice_enable', checked ? 'true' : 'false')}
                label={t('voiceEnable') as string}
              />
            </div>
            <Show when={tab.form.asr_provider === 'siliconflow'}>
              <TextInput
                type="password"
                label={t('voiceAsrApiKey') as string}
                value={tab.form.asr_api_key}
                onInput={(event) => tab.setForm('asr_api_key', event.currentTarget.value)}
              />
              <TextInput
                label={t('voiceAsrModel') as string}
                hint={t('voiceAsrModelSiliconFlowHint') as string}
                placeholder="FunAudioLLM/SenseVoiceSmall"
                value={tab.form.asr_model}
                onInput={(event) => tab.setForm('asr_model', event.currentTarget.value)}
              />
              <TextInput
                type="url"
                full
                label={t('voiceAsrEndpoint') as string}
                hint={t('voiceAsrEndpointSfHint') as string}
                placeholder="https://api.siliconflow.cn/v1"
                value={tab.form.asr_endpoint}
                onInput={(event) => tab.setForm('asr_endpoint', event.currentTarget.value)}
              />
            </Show>
            <Show when={tab.form.asr_provider === 'iflytek' || tab.form.asr_provider === 'iflytek_bigmodel'}>
              <TextInput
                label={t('voiceAsrAppId') as string}
                value={tab.form.asr_app_id}
                onInput={(event) => tab.setForm('asr_app_id', event.currentTarget.value)}
              />
              <TextInput
                type="password"
                label={t('voiceAsrApiKey') as string}
                hint={t('voiceAsrIflytekKeyHint') as string}
                value={tab.form.asr_api_key}
                onInput={(event) => tab.setForm('asr_api_key', event.currentTarget.value)}
              />
              <TextInput
                type="password"
                full
                label={t('voiceAsrApiSecret') as string}
                value={tab.form.asr_api_secret}
                onInput={(event) => tab.setForm('asr_api_secret', event.currentTarget.value)}
              />
              <TextInput
                full
                label={t('voiceAsrEndpoint') as string}
                hint={t('voiceAsrIflytekEndpointHint') as string}
                placeholder={tab.form.asr_provider === 'iflytek_bigmodel' ? 'wss://iat.xf-yun.com/v1' : 'wss://iat-api.xfyun.cn/v2/iat'}
                value={tab.form.asr_endpoint}
                onInput={(event) => tab.setForm('asr_endpoint', event.currentTarget.value)}
              />
            </Show>
            <TextInput
              type="password"
              label={t('voiceTtsApiKey') as string}
              value={tab.form.tts_api_key}
              onInput={(event) => tab.setForm('tts_api_key', event.currentTarget.value)}
            />
            <TextInput
              type="url"
              label={t('voiceTtsBaseUrl') as string}
              hint={t('voiceTtsBaseUrlHint') as string}
              placeholder="https://api.siliconflow.cn/v1"
              value={tab.form.tts_base_url}
              onInput={(event) => tab.setForm('tts_base_url', event.currentTarget.value)}
            />
            <TextInput
              label={t('voiceTtsModel') as string}
              placeholder="FunAudioLLM/CosyVoice2-0.5B"
              value={tab.form.tts_model}
              onInput={(event) => tab.setForm('tts_model', event.currentTarget.value)}
            />
            <TextInput
              label={t('voiceTtsVoice') as string}
              placeholder="FunAudioLLM/CosyVoice2-0.5B:alex"
              value={tab.form.tts_voice}
              onInput={(event) => tab.setForm('tts_voice', event.currentTarget.value)}
            />
            <TextInput
              label={t('voiceTtsVolume') as string}
              hint={t('voiceTtsVolumeHint') as string}
              placeholder="80"
              value={tab.form.tts_volume}
              onInput={(event) => tab.setForm('tts_volume', event.currentTarget.value)}
            />
          </div>
        </CollapsibleConfigBlock>
      </div>
      <SavePanel
        dirty={tab.dirty()}
        saving={tab.saving()}
        onSave={() => handleSave().catch(() => undefined)}
        onDiscard={tab.discard}
        note={t('restartHint') as string}
      />
    </TabShell>
  );
};
