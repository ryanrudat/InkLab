// Shared types for the InkLab proxy. Mirrors the Swift side (InkLabRecognition / ADR 0002).

export type UserKind = 'adult' | 'minorConsented' | 'minorUnconsented' | 'schoolManaged'

export interface Session {
  isOnline: boolean
  userKind: UserKind
  /** App Store §5.1.2(i): explicit permission to send data to third-party AI. */
  aiConsentGranted: boolean
  /** "Organizations Serving Minors" safeguard #1: age verification. */
  ageVerified: boolean
}

export type CloudDecision = { allowed: true } | { allowed: false; reason: string }

export type Domain = 'math' | 'text' | 'chemistry' | 'diagram'

export interface RecognitionRequest {
  session: Session
  /** Base64 PNG of the lassoed region (the only ink that leaves the device, and only with consent). */
  rasterPngBase64?: string
  strokes?: Array<{ points: Array<{ x: number; y: number; t?: number }> }>
  domain: Domain
  context?: string
}

export type FormalKind = 'latex' | 'smiles' | 'plainText' | 'unrecognized'

export interface RecognitionResult {
  formal: { kind: FormalKind; value: string }
  confidence: number
  readAs: string
}

// --- Anthropic client abstraction (mockable; the real call is HTTP) ---

export interface TextBlock { type: 'text'; text: string }
export interface ImageBlock { type: 'image'; source: { type: 'base64'; media_type: string; data: string } }
export type ContentBlock = TextBlock | ImageBlock

export interface AnthropicMessage { role: 'user' | 'assistant'; content: string | ContentBlock[] }
export interface AnthropicResponse { text: string; stopReason: string }
export interface CompleteOpts {
  system?: string
  messages: AnthropicMessage[]
  maxTokens?: number
  model?: string
  thinking?: { type: 'adaptive' | 'disabled' }
  effort?: 'low' | 'medium' | 'high' | 'max'
}
export interface AnthropicClient {
  complete(opts: CompleteOpts): Promise<AnthropicResponse>
}
