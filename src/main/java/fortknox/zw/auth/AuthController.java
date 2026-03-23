package fortknox.zw.auth;

import fortknox.zw.user.User;
import fortknox.zw.user.UserRepository;
import fortknox.zw.user.UserService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;

@RestController
@RequestMapping("/auth")
public class AuthController {

    private final AuthenticationManager authenticationManager;
    private final JwtService jwtService;
    private final RefreshTokenRepository refreshTokenRepository;
    private final UserService userService;
    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final long refreshTokenExpiry;

    public AuthController(AuthenticationManager authenticationManager,
                          JwtService jwtService,
                          RefreshTokenRepository refreshTokenRepository,
                          UserService userService,
                          UserRepository userRepository,
                          PasswordEncoder passwordEncoder,
                          @Value("${jwt.refresh-token-expiry:604800000}") long refreshTokenExpiry) {
        this.authenticationManager = authenticationManager;
        this.jwtService = jwtService;
        this.refreshTokenRepository = refreshTokenRepository;
        this.userService = userService;
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
        this.refreshTokenExpiry = refreshTokenExpiry;
    }

    @PostMapping("/register")
    @Transactional
    public ResponseEntity<?> register(@RequestBody RegisterRequest request) {
        if (userRepository.findByUsername(request.username()).isPresent()) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body("Username already taken");
        }

        userRepository.save(new User(request.username(), passwordEncoder.encode(request.password()), "ROLE_USER"));
        return ResponseEntity.status(HttpStatus.CREATED).build();
    }

    @PostMapping("/login")
    @Transactional
    public TokenResponse login(@RequestBody LoginRequest request) {
        authenticationManager.authenticate(
                new UsernamePasswordAuthenticationToken(request.username(), request.password()));

        User user = (User) userService.loadUserByUsername(request.username());
        refreshTokenRepository.revokeAllByUser(user);

        String accessToken = jwtService.generateAccessToken(user);
        String refreshToken = jwtService.generateRefreshToken(user);

        refreshTokenRepository.save(new RefreshToken(
                refreshToken, user, Instant.now().plusMillis(refreshTokenExpiry)));

        return new TokenResponse(accessToken, refreshToken);
    }

    @PostMapping("/refresh")
    @Transactional
    public ResponseEntity<?> refresh(@RequestBody RefreshRequest request) {
        RefreshToken stored = refreshTokenRepository.findByToken(request.refreshToken())
                .orElse(null);

        if (stored == null || stored.isRevoked() || stored.isExpired()) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("Refresh token invalid, expired, or revoked");
        }

        User user = stored.getUser();
        stored.setRevoked(true);

        String newAccessToken = jwtService.generateAccessToken(user);
        String newRefreshToken = jwtService.generateRefreshToken(user);

        refreshTokenRepository.save(new RefreshToken(
                newRefreshToken, user, Instant.now().plusMillis(refreshTokenExpiry)));

        return ResponseEntity.ok(new TokenResponse(newAccessToken, newRefreshToken));
    }

    @PostMapping("/logout")
    @Transactional
    public ResponseEntity<Void> logout(@RequestBody RefreshRequest request) {
        refreshTokenRepository.findByToken(request.refreshToken())
                .ifPresent(t -> t.setRevoked(true));
        return ResponseEntity.noContent().build();
    }

    public record RegisterRequest(String username, String password) {}
    public record LoginRequest(String username, String password) {}
    public record RefreshRequest(String refreshToken) {}
    public record TokenResponse(String accessToken, String refreshToken) {}
}
