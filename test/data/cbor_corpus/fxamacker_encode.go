// Encode the conformance corpus with fxamacker/cbor CoreDetEncOptions() and print `name hex` per case.
// Same corpus.json as cbor2_encode.py; see its docstring for the node shapes.
package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"strconv"

	"github.com/fxamacker/cbor/v2"
)

type node struct {
	T string          `json:"t"`
	V json.RawMessage `json:"v"`
}
type entry struct {
	Name  string `json:"name"`
	Value node   `json:"value"`
}

func build(n node) any {
	switch n.T {
	case "int":
		var s string
		json.Unmarshal(n.V, &s)
		i, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			panic(err)
		}
		return i
	case "float":
		var s string
		json.Unmarshal(n.V, &s)
		b, _ := hex.DecodeString(s)
		var bits uint64
		for _, x := range b {
			bits = bits<<8 | uint64(x)
		}
		return math.Float64frombits(bits)
	case "text":
		var s string
		json.Unmarshal(n.V, &s)
		return s
	case "bytes":
		var s string
		json.Unmarshal(n.V, &s)
		b, _ := hex.DecodeString(s)
		if b == nil {
			b = []byte{}
		}
		return b
	case "bool":
		var b bool
		json.Unmarshal(n.V, &b)
		return b
	case "null":
		return nil
	case "array":
		var items []node
		json.Unmarshal(n.V, &items)
		out := []any{}
		for _, it := range items {
			out = append(out, build(it))
		}
		return out
	case "map":
		var pairs [][2]json.RawMessage
		json.Unmarshal(n.V, &pairs)
		out := map[string]any{}
		for _, p := range pairs {
			var k string
			json.Unmarshal(p[0], &k)
			var v node
			json.Unmarshal(p[1], &v)
			out[k] = build(v)
		}
		return out
	}
	panic(n.T)
}

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	var corpus []entry
	if err := json.Unmarshal(data, &corpus); err != nil {
		panic(err)
	}
	em, err := cbor.CoreDetEncOptions().EncMode()
	if err != nil {
		panic(err)
	}
	for _, c := range corpus {
		b, err := em.Marshal(build(c.Value))
		if err != nil {
			panic(fmt.Sprintf("%s: %v", c.Name, err))
		}
		fmt.Println(c.Name, hex.EncodeToString(b))
	}
}
