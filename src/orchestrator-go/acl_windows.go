package main

import (
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

// privateACL builds a DACL granting full access only to the current user,
// SYSTEM and Administrators.
func privateACL() (*windows.ACL, error) {
	u, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	sys, err := windows.CreateWellKnownSid(windows.WinLocalSystemSid)
	if err != nil {
		return nil, err
	}
	adm, err := windows.CreateWellKnownSid(windows.WinBuiltinAdministratorsSid)
	if err != nil {
		return nil, err
	}
	ea := func(sid *windows.SID, tt windows.TRUSTEE_TYPE) windows.EXPLICIT_ACCESS {
		return windows.EXPLICIT_ACCESS{
			AccessPermissions: windows.GENERIC_ALL,
			AccessMode:        windows.SET_ACCESS,
			Inheritance:       windows.NO_INHERITANCE,
			Trustee: windows.TRUSTEE{
				TrusteeForm:  windows.TRUSTEE_IS_SID,
				TrusteeType:  tt,
				TrusteeValue: windows.TrusteeValueFromSID(sid),
			},
		}
	}
	return windows.ACLFromEntries([]windows.EXPLICIT_ACCESS{
		ea(u.User.Sid, windows.TRUSTEE_IS_USER),
		ea(sys, windows.TRUSTEE_IS_WELL_KNOWN_GROUP),
		ea(adm, windows.TRUSTEE_IS_WELL_KNOWN_GROUP),
	}, nil)
}

// restrictFileACL replaces the DACL of path with a protected one granting full
// access only to the current user, SYSTEM and Administrators. Unix file modes
// have no effect on Windows, so secrets (key.pem, orchestrator.json) would
// otherwise inherit the directory ACL (often Users:RX).
func restrictFileACL(path string) error {
	acl, err := privateACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
}

// createPrivateFile creates a new file (failing if it exists) whose protected
// DACL is set at creation time, so no other user can open it in between.
func createPrivateFile(path string) (*os.File, error) {
	acl, err := privateACL()
	if err != nil {
		return nil, err
	}
	sd, err := windows.NewSecurityDescriptor()
	if err != nil {
		return nil, err
	}
	if err := sd.SetDACL(acl, true, false); err != nil {
		return nil, err
	}
	if err := sd.SetControl(windows.SE_DACL_PROTECTED, windows.SE_DACL_PROTECTED); err != nil {
		return nil, err
	}
	sa := &windows.SecurityAttributes{SecurityDescriptor: sd}
	sa.Length = uint32(unsafe.Sizeof(*sa))
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(p, windows.GENERIC_WRITE, 0, sa, windows.CREATE_NEW, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, &os.PathError{Op: "create", Path: path, Err: err}
	}
	return os.NewFile(uintptr(h), path), nil
}

// writePrivateFile writes b atomically to path: the temp file is created with
// its private DACL already in place, then renamed over path.
func writePrivateFile(path string, b []byte) error {
	tmp := path + ".tmp"
	if err := os.Remove(tmp); err != nil && !os.IsNotExist(err) {
		return err
	}
	f, err := createPrivateFile(tmp)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}
