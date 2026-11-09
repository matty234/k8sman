package svcproxy

import (
	"errors"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestUnexpectedResponseAndStatusCode(t *testing.T) {
	se := &apierrors.StatusError{ErrStatus: metav1.Status{Code: 503, Details: &metav1.StatusDetails{Causes: []metav1.StatusCause{
		{Type: metav1.CauseTypeUnexpectedServerResponse, Message: "upstream down"},
	}}}}
	if got, ok := UnexpectedResponse(se); !ok || got != "upstream down" {
		t.Errorf("UnexpectedResponse = %q, %v", got, ok)
	}
	if _, ok := UnexpectedResponse(errors.New("plain")); ok {
		t.Error("UnexpectedResponse matched a non-Status error")
	}
	if c := StatusCode(0, se); c != 503 {
		t.Errorf("StatusCode(0) = %d", c)
	}
	if c := StatusCode(404, se); c != 404 {
		t.Errorf("StatusCode(404) = %d", c)
	}
}
