// Package svcproxy holds the mechanics shared by integrations that reach
// an in-cluster HTTP service through the Kubernetes API server's service
// proxy (internal/prom, internal/argoapi). Each caller keeps its own error
// type and message/reason mapping.
package svcproxy

import (
	"context"
	"errors"
	"net/url"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/rest"
)

// Do sends method to absPath with the query parameters, headers and (when
// non-nil) JSON body. It returns the response body, the HTTP status code
// (0 when none was received) and client-go's error for non-2xx answers.
func Do(ctx context.Context, rc rest.Interface, method, absPath string, q url.Values, header map[string]string, body []byte) (raw []byte, code int, err error) {
	req := rc.Verb(method).AbsPath(absPath)
	for k, vs := range q {
		for _, v := range vs {
			req = req.Param(k, v)
		}
	}
	for k, v := range header {
		req = req.SetHeader(k, v)
	}
	if body != nil {
		req = req.SetHeader("Content-Type", "application/json").Body(body)
	}
	raw, err = req.Do(ctx).StatusCode(&code).Raw()
	return raw, code, err
}

// TimedOut reports whether a failed request ran out of time.
func TimedOut(ctx context.Context, err error) bool {
	return errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded)
}

// StatusCode returns code, or the code of the Kubernetes Status in err when
// code is 0.
func StatusCode(code int, err error) int {
	var se apierrors.APIStatus
	if code == 0 && errors.As(err, &se) {
		code = int(se.Status().Code)
	}
	return code
}

// PlainText returns raw trimmed when it looks like a short plain-text
// message (under 512 bytes, not HTML), else "".
func PlainText(raw []byte) string {
	if len(raw) > 0 && len(raw) < 512 && !strings.HasPrefix(strings.TrimSpace(string(raw)), "<") {
		return strings.TrimSpace(string(raw))
	}
	return ""
}

// UnexpectedResponse returns the body client-go folded into a StatusError
// cause when the server's error body wasn't a Status.
func UnexpectedResponse(err error) (string, bool) {
	var se apierrors.APIStatus
	if !errors.As(err, &se) {
		return "", false
	}
	if d := se.Status().Details; d != nil {
		for _, c := range d.Causes {
			if c.Type == metav1.CauseTypeUnexpectedServerResponse && c.Message != "" {
				return c.Message, true
			}
		}
	}
	return "", false
}
