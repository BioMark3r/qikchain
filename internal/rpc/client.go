package rpc

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type Client struct {
	rpcURL  string
	timeout time.Duration
	http    *http.Client
}

type request struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int    `json:"id"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
}

type response struct {
	Result string    `json:"result"`
	Error  *rpcError `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func NewClient(rpcURL string, timeout time.Duration) *Client {
	return &Client{
		rpcURL:  rpcURL,
		timeout: timeout,
		http:    &http.Client{},
	}
}

func (c *Client) CallString(method string) (string, error) {
	payload := request{
		JSONRPC: "2.0",
		ID:      1,
		Method:  method,
		Params:  []any{},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequest(http.MethodPost, c.rpcURL, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")

	client := c.http
	client.Timeout = c.timeout

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("rpc http status: %s", resp.Status)
	}

	var out response
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}

	if out.Error != nil {
		return "", fmt.Errorf("rpc error %d: %s", out.Error.Code, out.Error.Message)
	}

	return out.Result, nil
}
