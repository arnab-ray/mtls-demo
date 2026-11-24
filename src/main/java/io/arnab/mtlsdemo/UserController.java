package io.arnab.mtlsdemo;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/users/v1")
public class UserController {

    private final UserService userService;

    public UserController(UserService userService) {
        this.userService = userService;
    }

    @PostMapping("")
    public ResponseEntity<Void> create(@RequestBody UserCreationRequest request) {
        userService.create(request);
        return ResponseEntity.ok().build();
    }

    @GetMapping("")
    public ResponseEntity<UserResponse> getUser(@RequestParam String email) {
        var user = userService.findByEmail(email);
        return user.map(ResponseEntity::ok).orElseGet(() -> ResponseEntity.notFound().build());
    }

    @DeleteMapping("")
    public ResponseEntity<Void> deleteUser(@RequestParam String email) {
        userService.delete(email);
        return ResponseEntity.ok().build();
    }
}
