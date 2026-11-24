package io.arnab.mtlsdemo;

import org.springframework.stereotype.Service;

import java.util.Optional;

@Service
public class UserService {

    private final UserRepository userRepository;

    public UserService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    public void create(UserCreationRequest request) {
        var user = new User(request.name(), request.email());
        userRepository.save(user);
    }

    public Optional<UserResponse> findByEmail(String email) {
        var maybeUser = userRepository.findByEmail(email);
        if (maybeUser.isPresent()) {
            var user = maybeUser.get();
            return Optional.of(new UserResponse(user.getId(), user.getName(), user.getEmail()));
        }
        return Optional.empty();
    }

    public void delete(String email) {
        var maybeUser = userRepository.findByEmail(email);
        maybeUser.ifPresent(user -> userRepository.save(user.inactivate()));
    }
}
