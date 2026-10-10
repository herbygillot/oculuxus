// Package beta uses alpha.
package beta

import "example.com/alpha"

// B embeds alpha.A.
type B struct{ alpha.A }
