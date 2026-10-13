package shapes

import "testing"

// testCircle is a fixture shared by the tests.
type testCircle struct {
	Circle
	name string
}

func TestArea(t *testing.T) {
	c := testCircle{Circle: Circle{Radius: 1}, name: "unit"}
	if c.Area() <= 0 {
		t.Errorf("%s: area %v", c.name, c.Area())
	}
}
