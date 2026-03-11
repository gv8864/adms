package signals

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"sync"
	"time"
)

// AuthToken represents a signed, time-bounded authorization credential
// that allows drift-inducing operations without triggering escalation.
type AuthToken struct {
	ManifestHash     string `json:"manifest_hash"`
	IssuedAt         int64  `json:"issued_at"`
	ExpiresAt        int64  `json:"expires_at"`
	WorkloadID       string `json:"workload_id"`
	DeploymentIntent string `json:"deployment_intent"`
}

// Authorizer computes A(t) — whether current drift is authorized
// under a cryptographically verified control plane.
type Authorizer struct {
	mu            sync.RWMutex
	pubkeyPath    string
	tokenDir      string
	cachedPubkey  *rsa.PublicKey
	auditLog      []AuthAuditEntry
}

type AuthAuditEntry struct {
	Timestamp  time.Time
	TokenPath  string
	Authorized bool
	Reason     string
}

func NewAuthorizer(pubkeyPath, tokenDir string) (*Authorizer, error) {
	a := &Authorizer{
		pubkeyPath: pubkeyPath,
		tokenDir:   tokenDir,
	}
	if err := a.loadPubkey(); err != nil {
		return nil, err
	}
	return a, nil
}

func (a *Authorizer) loadPubkey() error {
	data, err := os.ReadFile(a.pubkeyPath)
	if err != nil {
		return err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return os.ErrInvalid
	}
	pub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return err
	}
	rsaPub, ok := pub.(*rsa.PublicKey)
	if !ok {
		return os.ErrInvalid
	}
	a.cachedPubkey = rsaPub
	return nil
}

// IsAuthorized checks A(t): whether a valid, unexpired, correctly signed
// authorization token exists. Returns true only when both conditions hold:
// (i) the deployment intent is signed and validated, and
// (ii) the token has not expired (short-lived credential).
func (a *Authorizer) IsAuthorized() bool {
	a.mu.RLock()
	defer a.mu.RUnlock()

	tokenPath := a.tokenDir + "/auth-token.json"
	sigPath := a.tokenDir + "/auth-token.sig"

	// Read token
	tokenBytes, err := os.ReadFile(tokenPath)
	if err != nil {
		a.recordAudit(tokenPath, false, "token not found")
		return false
	}

	var token AuthToken
	if err := json.Unmarshal(tokenBytes, &token); err != nil {
		a.recordAudit(tokenPath, false, "invalid token JSON")
		return false
	}

	// Check TTL
	if time.Now().Unix() > token.ExpiresAt {
		a.recordAudit(tokenPath, false, "token expired")
		return false
	}

	// Verify signature
	sigBytes, err := os.ReadFile(sigPath)
	if err != nil {
		a.recordAudit(tokenPath, false, "signature not found")
		return false
	}

	hash := sha256.Sum256(tokenBytes)
	err = rsa.VerifyPKCS1v15(a.cachedPubkey, crypto.SHA256, hash[:], sigBytes)
	if err != nil {
		a.recordAudit(tokenPath, false, "signature verification failed")
		return false
	}

	a.recordAudit(tokenPath, true, "valid")
	return true
}

func (a *Authorizer) recordAudit(path string, authorized bool, reason string) {
	a.auditLog = append(a.auditLog, AuthAuditEntry{
		Timestamp:  time.Now(),
		TokenPath:  path,
		Authorized: authorized,
		Reason:     reason,
	})
}

// AuditLog returns a copy of the authorization audit trail.
func (a *Authorizer) AuditLog() []AuthAuditEntry {
	a.mu.RLock()
	defer a.mu.RUnlock()
	out := make([]AuthAuditEntry, len(a.auditLog))
	copy(out, a.auditLog)
	return out
}
