package shapes_test

import (
	"os"

	"example.com/simple/shapes"
)

func ExampleDescribe() {
	shapes.Describe(os.Stdout, shapes.Circle{Radius: 2})
}
