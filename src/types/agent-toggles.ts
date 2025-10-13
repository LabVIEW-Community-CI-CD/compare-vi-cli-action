export const AGENT_TOGGLES_SCHEMA_ID = 'agent-toggles/v1';
export const AGENT_TOGGLE_VALUES_SCHEMA_ID = 'agent-toggle-values/v1';
export const AGENT_TOGGLES_SCHEMA_VERSION = '1.0.0';

export type ToggleValue = string | number | boolean;

export type ToggleValueType = 'string' | 'number' | 'boolean';

export interface ToggleMatch {
  describe?: string;
  it?: string;
  tags?: string[];
}

export interface ToggleVariant {
  /**
   * Optional identifier for referencing the variant in telemetry or consumers.
   */
  id?: string;
  /**
   * Human-readable note describing why this variant exists.
   */
  description?: string;
  /**
   * Matching metadata that activates the variant when all criteria are satisfied.
   */
  match?: ToggleMatch;
  /**
   * Optional documentation anchors.
   */
  docs?: string[];
  /**
   * Value to apply when the variant matches.
   */
  value: ToggleValue;
}

export interface ToggleMetadata {
  key: string;
  description: string;
  type: ToggleValueType;
  defaultValue: ToggleValue;
  scopes?: string[];
  tags?: string[];
  docs?: string[];
  deprecated?: boolean;
  variants?: ToggleVariant[];
}

export interface ToggleProfile {
  id: string;
  description: string;
  inherits?: string[];
  values: Record<string, ToggleValue>;
  docs?: string[];
  tags?: string[];
}

export interface ToggleManifest {
  schema: typeof AGENT_TOGGLES_SCHEMA_ID;
  schemaVersion: string;
  generatedAtUtc: string;
  toggles: ToggleMetadata[];
  profiles: ToggleProfile[];
}

export type ToggleResolutionSource = 'default' | 'profile' | 'variant' | 'environment';

export interface ToggleResolution {
  key: string;
  value: ToggleValue;
  valueType: ToggleValueType;
  /**
   * Indicates whether the resolved value originates from the default definition,
   * a profile overlay, or a variant match.
   */
  source: ToggleResolutionSource;
  /**
   * For profile-sourced values we expose the first profile that applied the override.
   */
  profile?: string;
  /**
   * Identifier of the variant that applied, when applicable.
   */
  variant?: string;
  /**
   * Optional description echo for downstream consumers.
   */
  description?: string;
}

export interface ToggleResolutionContext {
  profiles?: string[];
  describe?: string;
  it?: string;
  tags?: string[];
}

export interface ToggleValuesPayload {
  schema: typeof AGENT_TOGGLE_VALUES_SCHEMA_ID;
  schemaVersion: string;
  generatedAtUtc: string;
  manifestDigest: string;
  manifestGeneratedAtUtc: string;
  profiles: string[];
  context: {
    describe?: string;
    it?: string;
    tags?: string[];
  };
  values: Record<string, ToggleResolution>;
}

export interface ToggleContractBundle {
  manifest: ToggleManifest;
  manifestDigest: string;
}
