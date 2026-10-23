package main

import (
	"errors"
	"net/http"
	"strings"
)

// Group is a named, ordered section of the project rail.
type Group struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Order     int    `json:"order"`
	Collapsed bool   `json:"collapsed"`
}

const maxGroupName = 80

func cleanGroupName(s string) (string, bool) {
	s = strings.TrimSpace(s)
	return s, s != "" && len(s) <= maxGroupName && !hasControlChar(s)
}

func groupExists(c *Config, id string) bool {
	for _, g := range c.Groups {
		if g.ID == id {
			return true
		}
	}
	return false
}

func (s *Server) handleGroups(w http.ResponseWriter, r *http.Request) {
	out := []Group{}
	s.store.View(func(c *Config) { out = append(out, c.Groups...) })
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleGroupCreate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if err := readJSON(r, &req); err != nil {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	name, ok := cleanGroupName(req.Name)
	if !ok {
		apiErr(w, http.StatusBadRequest, "invalid_group_name")
		return
	}
	var g Group
	err := s.store.Update(func(c *Config) error {
		max := 0
		for _, x := range c.Groups {
			if strings.EqualFold(x.Name, name) {
				return errors.New("duplicate")
			}
			if x.Order > max {
				max = x.Order
			}
		}
		g = Group{ID: randomToken(9), Name: name, Order: max + 1}
		c.Groups = append(c.Groups, g)
		return nil
	})
	if err != nil {
		apiErr(w, http.StatusConflict, "group_exists")
		return
	}
	writeJSON(w, http.StatusCreated, g)
}

func (s *Server) handleGroupUpdate(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		Name      *string `json:"name"`
		Order     *int    `json:"order"`
		Collapsed *bool   `json:"collapsed"`
	}
	if err := readJSON(r, &req); err != nil || (req.Name == nil && req.Order == nil && req.Collapsed == nil) {
		apiErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	name := ""
	if req.Name != nil {
		var ok bool
		if name, ok = cleanGroupName(*req.Name); !ok {
			apiErr(w, http.StatusBadRequest, "invalid_group_name")
			return
		}
	}
	var g Group
	status, code := 0, ""
	err := s.store.Update(func(c *Config) error {
		for i := range c.Groups {
			if c.Groups[i].ID != id {
				continue
			}
			if req.Name != nil {
				for _, x := range c.Groups {
					if x.ID != id && strings.EqualFold(x.Name, name) {
						status, code = http.StatusConflict, "group_exists"
						return errors.New("duplicate")
					}
				}
				c.Groups[i].Name = name
			}
			if req.Order != nil {
				c.Groups[i].Order = *req.Order
			}
			if req.Collapsed != nil {
				c.Groups[i].Collapsed = *req.Collapsed
			}
			g = c.Groups[i]
			return nil
		}
		status, code = http.StatusNotFound, "not_found"
		return errors.New("not found")
	})
	if err != nil {
		apiErr(w, status, code)
		return
	}
	writeJSON(w, http.StatusOK, g)
}

// handleGroupDelete removes the group; its projects become ungrouped and stay registered.
func (s *Server) handleGroupDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	err := s.store.Update(func(c *Config) error {
		for i := range c.Groups {
			if c.Groups[i].ID == id {
				c.Groups = append(c.Groups[:i], c.Groups[i+1:]...)
				for j := range c.Projects {
					if c.Projects[j].GroupID == id {
						c.Projects[j].GroupID = ""
					}
				}
				return nil
			}
		}
		return errors.New("not found")
	})
	if err != nil {
		apiErr(w, http.StatusNotFound, "not_found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
